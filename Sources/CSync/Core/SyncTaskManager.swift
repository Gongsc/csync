import Foundation

@MainActor
final class SyncTaskManager: ObservableObject {
    @Published private(set) var tasks: [UUID: SyncTask] = [:]
    @Published var maxConcurrentTasks: Int = 3 {
        didSet {
            if maxConcurrentTasks < 1 { maxConcurrentTasks = 1 }
            if maxConcurrentTasks > 8 { maxConcurrentTasks = 8 }
            scheduleNextIfNeeded()
        }
    }

    private var pendingProjectIDs: [UUID] = []
    private var preflightingProjectIDs: Set<UUID> = []
    private var projectsByID: [UUID: Project] = [:]
    private var runningProcesses: [UUID: RunningSync] = [:]
    private var manuallyCancelledProjectIDs: Set<UUID> = []
    private var activeConflictRequests: [UUID: ConflictResolutionRequest] = [:]
    private var syncFileStates: [UUID: [String: SyncFileStatus]] = [:]
    private var autoRetryAttemptsByProjectID: [UUID: Int] = [:]
    private var autoRetryWorkItemByProjectID: [UUID: DispatchWorkItem] = [:]
    private let maxRecordedFiles = 200
    private let maxAutoRetryAttempts = 2
    private let autoRetryBaseDelay: TimeInterval = 2

    private let executor = RsyncExecutor()
    private let conflictDetector = ConflictDetector()
    private let conflictBaselineStore = ConflictBaselineStore()

    var onProjectSynced: ((UUID, Date) -> Void)?
    var onConflictDetected: ((ConflictResolutionRequest) -> Void)?
    var onProjectSyncFailed: ((UUID, String, String) -> Void)?
    var passwordProvider: ((UUID) -> String?)?

    var orderedTasks: [SyncTask] {
        tasks.values.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    var runningCount: Int {
        tasks.values.filter({ $0.state.isRunning }).count
    }

    var queuedCount: Int {
        tasks.values.filter({ $0.state.isQueued }).count
    }

    var failedCount: Int {
        tasks.values.filter({ $0.state.isFailed }).count
    }

    private func makeTask(
        projectID: UUID,
        projectName: String,
        state: SyncTaskState,
        triggerKind: SyncTriggerKind? = nil,
        fileResults: [SyncFileResult]? = nil
    ) -> SyncTask {
        let resolvedFiles = fileResults ?? tasks[projectID]?.fileResults ?? []
        let resolvedTriggerKind = triggerKind ?? tasks[projectID]?.triggerKind ?? .manual
        return SyncTask(
            projectID: projectID,
            projectName: projectName,
            state: state,
            triggerKind: resolvedTriggerKind,
            fileResults: resolvedFiles
        )
    }

    func enqueueSync(
        for project: Project,
        reason: String = "手动触发",
        triggerKind: SyncTriggerKind = .manual,
        isAutoRetry: Bool = false
    ) {
        projectsByID[project.id] = project

        if !isAutoRetry {
            clearAutoRetryState(for: project.id)
        }

        if runningProcesses[project.id] != nil || pendingProjectIDs.contains(project.id) {
            return
        }

        tasks[project.id] = makeTask(
            projectID: project.id,
            projectName: project.name,
            state: .queued(reason: reason),
            triggerKind: triggerKind
        )
        pendingProjectIDs.append(project.id)
        scheduleNextIfNeeded()
    }

    private func recordSyncLine(projectID: UUID, line: String) {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var states = syncFileStates[projectID] ?? [:]

        if let failedPath = failedPath(from: normalized) {
            states[failedPath] = .failed
            syncFileStates[projectID] = states
            return
        }

        if let succeededPath = succeededPathCandidate(from: normalized), states[succeededPath] == nil {
            states[succeededPath] = .succeeded
            syncFileStates[projectID] = states
        }
    }

    private func fileResults(for projectID: UUID) -> [SyncFileResult] {
        let states = syncFileStates[projectID] ?? [:]

        return states
            .map { SyncFileResult(path: $0.key, status: $0.value) }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .failed
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .prefix(maxRecordedFiles)
            .map { $0 }
    }

    private func failedPath(from line: String) -> String? {
        if let range = line.range(of: #""([^"]+)".*failed:"#, options: .regularExpression) {
            let matched = String(line[range])
            if let pathRange = matched.range(of: #""([^"]+)""#, options: .regularExpression) {
                return normalizePath(String(matched[pathRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }

        if line.localizedCaseInsensitiveContains("permission denied") || line.localizedCaseInsensitiveContains("failed") {
            if let candidate = succeededPathCandidate(from: line) {
                return candidate
            }
        }

        return nil
    }

    private func succeededPathCandidate(from line: String) -> String? {
        let lower = line.lowercased()

        let ignoredPrefixes = [
            "sending incremental file list",
            "sent ",
            "total size is",
            "speedup is",
            "rsync:",
            "receiving incremental file list",
            "building file list"
        ]

        if ignoredPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return nil
        }

        if lower.contains("to-check=") || line.contains("%") {
            return nil
        }

        if line == "./" || line == "." {
            return nil
        }

        if lower.hasPrefix("deleting ") {
            let path = String(line.dropFirst("deleting ".count))
            return normalizePath(path)
        }

        if line.contains(": ") && !line.hasPrefix("./") {
            return nil
        }

        return normalizePath(line)
    }

    private func normalizePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "." || trimmed == "./" { return nil }
        return trimmed
    }

    func enqueueSync(for projects: [Project], reason: String = "批量触发", triggerKind: SyncTriggerKind = .manual) {
        projects.forEach { enqueueSync(for: $0, reason: reason, triggerKind: triggerKind, isAutoRetry: false) }
    }

    func cancel(projectID: UUID) {
        clearAutoRetryState(for: projectID)
        pendingProjectIDs.removeAll(where: { $0 == projectID })

        if let request = activeConflictRequests.removeValue(forKey: projectID) {
            request.resolve(.skip)
        }

        if preflightingProjectIDs.remove(projectID) != nil {
            manuallyCancelledProjectIDs.insert(projectID)
            if let existing = tasks[projectID] {
                tasks[projectID] = makeTask(
                    projectID: existing.projectID,
                    projectName: existing.projectName,
                    state: .cancelled
                )
            }
            scheduleNextIfNeeded()
            return
        }

        if let process = runningProcesses[projectID] {
            manuallyCancelledProjectIDs.insert(projectID)
            process.cancel()
            return
        }

        if let existing = tasks[projectID] {
            tasks[projectID] = makeTask(
                projectID: existing.projectID,
                projectName: existing.projectName,
                state: .cancelled
            )
        }
    }

    func retryFailed(projectID: UUID) {
        guard
            let project = projectsByID[projectID],
            let task = tasks[projectID],
            task.state.isFailed
        else {
            return
        }

        enqueueSync(for: project, reason: "失败重试", triggerKind: .manual, isAutoRetry: false)
    }

    private func clearAutoRetryState(for projectID: UUID) {
        autoRetryWorkItemByProjectID[projectID]?.cancel()
        autoRetryWorkItemByProjectID[projectID] = nil
        autoRetryAttemptsByProjectID[projectID] = 0
    }

    private func clearPendingAutoRetryWorkItem(for projectID: UUID) {
        autoRetryWorkItemByProjectID[projectID]?.cancel()
        autoRetryWorkItemByProjectID[projectID] = nil
    }

    private func scheduleAutoRetryIfNeeded(projectID: UUID, projectName: String, message: String) {
        guard let project = projectsByID[projectID] else { return }
        guard SyncFailureClassifier.isLikelyTransientNetworkFailure(message: message) else { return }

        let currentAttempt = autoRetryAttemptsByProjectID[projectID] ?? 0
        guard currentAttempt < maxAutoRetryAttempts else { return }

        let nextAttempt = currentAttempt + 1
        autoRetryAttemptsByProjectID[projectID] = nextAttempt

        let delay = autoRetryBaseDelay * pow(2, Double(nextAttempt - 1))
        let reason = "网络抖动自动重试(\(nextAttempt)/\(maxAutoRetryAttempts))"
        let triggerKind = tasks[projectID]?.triggerKind ?? .manual

        clearPendingAutoRetryWorkItem(for: projectID)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoRetryWorkItemByProjectID[projectID] = nil
            self.enqueueSync(for: project, reason: reason, triggerKind: triggerKind, isAutoRetry: true)
        }

        autoRetryWorkItemByProjectID[projectID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

        tasks[projectID] = makeTask(
            projectID: projectID,
            projectName: projectName,
            state: .queued(reason: reason)
        )
    }

    private func scheduleNextIfNeeded() {
        while runningProcesses.count + preflightingProjectIDs.count < maxConcurrentTasks, !pendingProjectIDs.isEmpty {
            let nextID = pendingProjectIDs.removeFirst()
            guard let project = projectsByID[nextID] else { continue }
            start(project)
        }
    }

    private func start(_ project: Project) {
        preflightingProjectIDs.insert(project.id)
        syncFileStates[project.id] = [:]
        tasks[project.id] = makeTask(
            projectID: project.id,
            projectName: project.name,
            state: .running(progress: 0, message: "冲突检测中"),
            fileResults: []
        )

        let password: String?
        do {
            password = try resolvePassword(for: project)
        } catch {
            preflightingProjectIDs.remove(project.id)
            let message = error.localizedDescription
            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .failed(message)
            )
            onProjectSyncFailed?(project.id, project.name, message)
            scheduleNextIfNeeded()
            return
        }

        let baseline = conflictBaselineStore.load(projectID: project.id)
        conflictDetector.detectConflicts(project: project, baseline: baseline, password: password) { [weak self] result in
            Task { @MainActor in
                self?.handleConflictDetectionResult(result, for: project, password: password)
            }
        }
    }

    private func handleConflictDetectionResult(_ result: Result<[String], ConflictDetectionError>, for project: Project, password: String?) {
        guard preflightingProjectIDs.contains(project.id) else {
            return
        }

        if manuallyCancelledProjectIDs.remove(project.id) != nil {
            preflightingProjectIDs.remove(project.id)
            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .cancelled
            )
            scheduleNextIfNeeded()
            return
        }

        switch result {
        case .success(let conflicts):
            if conflicts.isEmpty {
                launchSync(project, direction: .localToRemote, initialMessage: "准备同步", password: password)
                return
            }

            let handlingMode = project.conflictHandlingMode ?? .askEveryTime
            if let automaticDecision = handlingMode.automaticDecision {
                let message: String
                switch automaticDecision {
                case .localOverride:
                    message = "检测到冲突，按默认策略：本地覆盖远端"
                case .remoteOverride:
                    message = "检测到冲突，按默认策略：远端覆盖本地"
                case .skip:
                    message = "检测到冲突，按默认策略：跳过"
                }

                tasks[project.id] = makeTask(
                    projectID: project.id,
                    projectName: project.name,
                    state: .running(progress: 0, message: message)
                )

                handleConflictDecision(automaticDecision, for: project, conflictCount: conflicts.count, password: password)
                return
            }

            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .running(progress: 0, message: "检测到 \(conflicts.count) 个冲突，等待决策")
            )

            let request = ConflictResolutionRequest(project: project, conflictingFiles: conflicts) { [weak self] decision in
                DispatchQueue.main.async {
                    self?.handleConflictDecision(decision, for: project, conflictCount: conflicts.count, password: password)
                }
            }

            activeConflictRequests[project.id] = request
            if let onConflictDetected {
                onConflictDetected(request)
            } else {
                request.resolve(.skip)
            }
        case .failure(let error):
            preflightingProjectIDs.remove(project.id)
            let message = "冲突检测失败：\(error.localizedDescription)"
            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .failed(message)
            )
            onProjectSyncFailed?(project.id, project.name, message)
            scheduleNextIfNeeded()
        }
    }

    private func handleConflictDecision(_ decision: ConflictResolution, for project: Project, conflictCount: Int, password: String?) {
        activeConflictRequests.removeValue(forKey: project.id)

        if manuallyCancelledProjectIDs.remove(project.id) != nil {
            preflightingProjectIDs.remove(project.id)
            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .cancelled
            )
            scheduleNextIfNeeded()
            return
        }

        switch decision {
        case .localOverride:
            launchSync(project, direction: .localToRemote, initialMessage: "按本地覆盖远端", password: password)
        case .remoteOverride:
            launchSync(project, direction: .remoteToLocal, initialMessage: "按远端覆盖本地", password: password)
        case .skip:
            preflightingProjectIDs.remove(project.id)
            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .failed("检测到 \(conflictCount) 个冲突，已跳过")
            )
            scheduleNextIfNeeded()
        }
    }

    private func launchSync(_ project: Project, direction: SyncDirection, initialMessage: String, password: String?) {
        preflightingProjectIDs.remove(project.id)

        tasks[project.id] = makeTask(
            projectID: project.id,
            projectName: project.name,
            state: .running(progress: 0, message: initialMessage)
        )

        do {
            let handle = try executor.startSync(
                project: project,
                direction: direction,
                password: password,
                progress: { [weak self] progress, message in
                    DispatchQueue.main.async {
                        self?.updateProgress(projectID: project.id, projectName: project.name, progress: progress, message: message)
                    }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.finish(projectID: project.id, projectName: project.name, result: result)
                    }
                }
            )
            runningProcesses[project.id] = handle
        } catch {
            tasks[project.id] = makeTask(
                projectID: project.id,
                projectName: project.name,
                state: .failed(error.localizedDescription)
            )
            scheduleNextIfNeeded()
        }
    }

    private func resolvePassword(for project: Project) throws -> String? {
        guard project.usePasswordAuth else {
            return nil
        }

        guard let storedPassword = passwordProvider?(project.id), !storedPassword.isEmpty else {
            throw SyncExecutionError.launchFailed("已启用密码登录，但当前会话无可用密码。请在主机管理中为该主机重新设置 SSH 密码后再同步。")
        }

        return storedPassword
    }

    private func updateProgress(projectID: UUID, projectName: String, progress: Double?, message: String) {
        guard runningProcesses[projectID] != nil else { return }

        recordSyncLine(projectID: projectID, line: message)

        let normalizedProgress: Double
        if let progress {
            normalizedProgress = min(max(progress, 0), 1)
        } else if case .running(let existing, _) = tasks[projectID]?.state {
            normalizedProgress = existing
        } else {
            normalizedProgress = 0
        }

        tasks[projectID] = makeTask(
            projectID: projectID,
            projectName: projectName,
            state: .running(progress: normalizedProgress, message: message),
            fileResults: fileResults(for: projectID)
        )
    }

    private func finish(projectID: UUID, projectName: String, result: Result<Void, SyncExecutionError>) {
        runningProcesses[projectID] = nil

        if manuallyCancelledProjectIDs.remove(projectID) != nil {
            clearAutoRetryState(for: projectID)
            tasks[projectID] = makeTask(
                projectID: projectID,
                projectName: projectName,
                state: .cancelled
            )
            syncFileStates[projectID] = nil
            scheduleNextIfNeeded()
            return
        }

        switch result {
        case .success:
            clearAutoRetryState(for: projectID)
            let date = Date()
            tasks[projectID] = makeTask(
                projectID: projectID,
                projectName: projectName,
                state: .succeeded(date),
                fileResults: fileResults(for: projectID)
            )
            onProjectSynced?(projectID, date)

            if let project = projectsByID[projectID] {
                persistConflictBaseline(for: project)
            }
        case .failure(let error):
            error.localizedDescription
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .forEach { line in
                    recordSyncLine(projectID: projectID, line: line)
                }

            let failureMessage = error.localizedDescription

            tasks[projectID] = makeTask(
                projectID: projectID,
                projectName: projectName,
                state: .failed(failureMessage),
                fileResults: fileResults(for: projectID)
            )

            onProjectSyncFailed?(projectID, projectName, failureMessage)
            scheduleAutoRetryIfNeeded(projectID: projectID, projectName: projectName, message: failureMessage)
        }

        syncFileStates[projectID] = nil

        scheduleNextIfNeeded()
    }

    private func persistConflictBaseline(for project: Project) {
        let detector = conflictDetector
        let store = conflictBaselineStore
        DispatchQueue.global(qos: .utility).async {
            let snapshot = detector.buildLocalSnapshot(project: project)
            store.save(snapshot: snapshot, for: project.id)
        }
    }
}
