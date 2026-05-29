import AppKit
import Combine
import Foundation

struct ProjectEditorContext: Identifiable {
    let id = UUID()
    let project: Project?
}

@MainActor
final class AppState: ObservableObject {
    let projectStore: ProjectStore
    let hostStore: HostStore
    let syncManager: SyncTaskManager
    let autoSyncService: AutoSyncService
    let hostPasswordCipher: HostPasswordCipher
    let hostConnectionTester: HostConnectionTester

    @Published var activeConflictRequest: ConflictResolutionRequest?
    @Published var projectEditorContext: ProjectEditorContext?
    private var pendingConflictRequests: [ConflictResolutionRequest] = []
    private var cancellables: Set<AnyCancellable> = []
    private var hostPasswordCache: [UUID: String] = [:]
    private var missingHostPasswordIDs: Set<UUID> = []

    init(
        projectStore: ProjectStore = ProjectStore(),
        hostStore: HostStore = HostStore(),
        syncManager: SyncTaskManager = SyncTaskManager(),
        autoSyncService: AutoSyncService = AutoSyncService(),
        hostPasswordCipher: HostPasswordCipher = .shared,
        hostConnectionTester: HostConnectionTester = HostConnectionTester()
    ) {
        self.projectStore = projectStore
        self.hostStore = hostStore
        self.syncManager = syncManager
        self.autoSyncService = autoSyncService
        self.hostPasswordCipher = hostPasswordCipher
        self.hostConnectionTester = hostConnectionTester

        bindStateForwarding()

        self.syncManager.onProjectSynced = { [weak self] projectID, date in
            self?.projectStore.markSynced(projectID: projectID, at: date)
        }

        self.syncManager.onConflictDetected = { [weak self] request in
            self?.enqueueConflictRequest(request)
        }

        self.syncManager.passwordProvider = { [weak self] projectID in
            guard let self else { return nil }

            if let project = self.projectStore.project(for: projectID) {
                if self.isHostManagedProject(project) {
                    return self.passwordForProjectFromHost(project)
                }
            }

            return nil
        }

        migrateHostAuthPreferencesIfNeeded()

        self.autoSyncService.start(projectStore: projectStore, syncManager: syncManager)
    }

    private func bindStateForwarding() {
        projectStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        hostStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        syncManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var menuBarSymbolName: String {
        if syncManager.runningCount > 0 {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        if syncManager.failedCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        return "arrow.triangle.2.circlepath.circle"
    }

    func upsertProject(_ project: Project) {
        projectStore.upsert(project)
        autoSyncService.refreshWatchers()
    }

    @discardableResult
    func upsertHost(_ host: ManagedHost, password: String?, keepExistingPassword: Bool) -> Bool {
        var resolvedHost = host

        if let password, !password.isEmpty {
            guard let encryptedPassword = hostPasswordCipher.encrypt(password) else {
                return false
            }

            resolvedHost.encryptedPassword = encryptedPassword
            hostPasswordCache[host.id] = password
            missingHostPasswordIDs.remove(host.id)
            resolvedHost.prefersPasswordAuth = true
        } else if !keepExistingPassword {
            resolvedHost.encryptedPassword = nil
            hostPasswordCache.removeValue(forKey: host.id)
            missingHostPasswordIDs.insert(host.id)
            resolvedHost.prefersPasswordAuth = false
        } else if let existing = hostStore.host(for: host.id) {
            resolvedHost.encryptedPassword = existing.encryptedPassword
            resolvedHost.prefersPasswordAuth = existing.prefersPasswordAuth
        }

        hostStore.upsert(resolvedHost)
        syncProjectsLinkedToHost(resolvedHost)
        return true
    }

    func removeHost(_ host: ManagedHost) {
        hostPasswordCache.removeValue(forKey: host.id)
        missingHostPasswordIDs.remove(host.id)
        hostStore.remove(hostID: host.id)
    }

    func hostPassword(for hostID: UUID) -> String? {
        if let cached = hostPasswordCache[hostID] {
            NSLog("[CSync][HostPassword] 命中缓存 hostID=\(hostID.uuidString)")
            return cached
        }

        if missingHostPasswordIDs.contains(hostID) {
            NSLog("[CSync][HostPassword] 命中空密码缓存 hostID=\(hostID.uuidString)")
            return nil
        }

        guard let host = hostStore.host(for: hostID) else {
            missingHostPasswordIDs.insert(hostID)
            NSLog("[CSync][HostPassword] 主机不存在 hostID=\(hostID.uuidString)")
            return nil
        }

        guard let encryptedPassword = host.encryptedPassword, !encryptedPassword.isEmpty else {
            missingHostPasswordIDs.insert(hostID)
            NSLog("[CSync][HostPassword] 主机未配置密码 hostID=\(hostID.uuidString)")
            return nil
        }

        NSLog("[CSync][HostPassword] 缓存未命中，尝试解密主机密码 hostID=\(hostID.uuidString)")
        let loaded = hostPasswordCipher.decrypt(encryptedPassword)
        if let loaded {
            hostPasswordCache[hostID] = loaded
            missingHostPasswordIDs.remove(hostID)
            NSLog("[CSync][HostPassword] 主机密码解密成功 hostID=\(hostID.uuidString)")
        } else {
            missingHostPasswordIDs.insert(hostID)
            NSLog("[CSync][HostPassword] 主机密码解密为空 hostID=\(hostID.uuidString)")
        }

        return loaded
    }

    func testHostConnection(
        host: ManagedHost,
        passwordOverride: String? = nil,
        completion: @escaping (Result<String, HostConnectionTestError>) -> Void
    ) {
        let overrideProvided = (passwordOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let resolvedPassword: String?
        if let passwordOverride {
            let trimmed = passwordOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedPassword = trimmed.isEmpty ? nil : passwordOverride
        } else {
            resolvedPassword = hostPassword(for: host.id)
        }

        let authMode = (resolvedPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? "password" : "publickey"
        NSLog("[CSync][HostTest] 解析认证模式 host=\(host.location), override=\(overrideProvided), auth=\(authMode)")

        hostConnectionTester.test(host: host, password: resolvedPassword) { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func removeProject(_ project: Project) {
        syncManager.cancel(projectID: project.id)
        projectStore.remove(projectID: project.id)
        autoSyncService.refreshWatchers()
    }

    func syncNow(project: Project) {
        syncManager.enqueueSync(for: project, reason: "手动触发", triggerKind: .manual)
    }

    func syncAllProjects() {
        syncManager.enqueueSync(for: projectStore.projects, reason: "手动批量触发", triggerKind: .manual)
    }

    func setAutoSyncEnabled(_ enabled: Bool, for projectID: UUID) {
        guard var project = projectStore.project(for: projectID) else { return }
        guard project.autoSync != enabled else { return }

        project.autoSync = enabled
        projectStore.upsert(project)
        autoSyncService.refreshWatchers()
    }

    func requestCreateProjectEditor() {
        projectEditorContext = ProjectEditorContext(project: nil)
        revealMainWindow()
    }

    func requestEditProjectEditor(projectID: UUID?) {
        guard let project = projectStore.project(for: projectID) else { return }
        projectEditorContext = ProjectEditorContext(project: project)
        revealMainWindow()
    }

    func requestEditProjectEditor(project: Project) {
        projectEditorContext = ProjectEditorContext(project: project)
        revealMainWindow()
    }

    func resolveActiveConflict(_ decision: ConflictResolution) {
        guard let request = activeConflictRequest else { return }
        request.resolve(decision)
        activeConflictRequest = nil
        presentNextConflictIfNeeded()
    }

    private func enqueueConflictRequest(_ request: ConflictResolutionRequest) {
        if activeConflictRequest == nil {
            activeConflictRequest = request
            revealMainWindow()
            return
        }

        pendingConflictRequests.append(request)
    }

    private func presentNextConflictIfNeeded() {
        guard activeConflictRequest == nil, !pendingConflictRequests.isEmpty else { return }
        activeConflictRequest = pendingConflictRequests.removeFirst()
        revealMainWindow()
    }

    private func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    private func passwordForProjectFromHost(_ project: Project) -> String? {
        if let hostID = project.hostID,
           let host = hostStore.host(for: hostID),
           let password = hostPassword(for: host.id),
           !password.isEmpty {
            return password
        }

        if let matchedHost = hostStore.hosts.first(where: {
            $0.address == project.remoteHost && $0.username == project.remoteUser
        }),
        let password = hostPassword(for: matchedHost.id),
        !password.isEmpty {
            return password
        }

        return nil
    }

    private func isHostManagedProject(_ project: Project) -> Bool {
        if project.hostID != nil {
            return true
        }

        return hostStore.hosts.contains {
            $0.address == project.remoteHost && $0.username == project.remoteUser
        }
    }

    private func syncProjectsLinkedToHost(_ host: ManagedHost) {
        let linkedProjects = projectStore.projects.filter { $0.hostID == host.id }
        guard !linkedProjects.isEmpty else { return }

        let hasHostPassword = host.prefersPasswordAuth

        for var project in linkedProjects {
            var changed = false
            if project.remoteHost != host.address {
                project.remoteHost = host.address
                changed = true
            }
            if project.remoteUser != host.username {
                project.remoteUser = host.username
                changed = true
            }

            if project.usePasswordAuth != hasHostPassword {
                project.usePasswordAuth = hasHostPassword
                changed = true
            }

            if changed {
                projectStore.upsert(project)
            }
        }
    }

    private func migrateHostAuthPreferencesIfNeeded() {
        for var host in hostStore.hosts {
            let hasPassword = !(host.encryptedPassword?.isEmpty ?? true)
            if host.prefersPasswordAuth != hasPassword {
                host.prefersPasswordAuth = hasPassword
                hostStore.upsert(host)
            }
        }
    }
}
