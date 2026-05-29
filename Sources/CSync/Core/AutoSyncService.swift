import Foundation

@MainActor
final class AutoSyncService {
    private struct WatchEntry {
        let rootPath: String
        let watcher: FileSystemEventWatcher
    }

    private weak var projectStore: ProjectStore?
    private weak var syncManager: SyncTaskManager?

    private var watchEntries: [UUID: WatchEntry] = [:]
    private var lastTriggeredAtByProject: [UUID: Date] = [:]

    private let debounceInterval: TimeInterval = 2

    func start(projectStore: ProjectStore, syncManager: SyncTaskManager) {
        stop()
        self.projectStore = projectStore
        self.syncManager = syncManager
        refreshWatchers()
    }

    func stop() {
        watchEntries.values.forEach { $0.watcher.stop() }
        watchEntries.removeAll()
        lastTriggeredAtByProject.removeAll()
    }

    func refreshWatchers() {
        guard let projectStore else { return }

        let activeProjects = projectStore.projects.filter { project in
            project.autoSync && isValidDirectory(project.localPath)
        }

        let activeProjectIDs = Set(activeProjects.map(\.id))

        for (projectID, entry) in watchEntries where !activeProjectIDs.contains(projectID) {
            entry.watcher.stop()
            watchEntries.removeValue(forKey: projectID)
            lastTriggeredAtByProject.removeValue(forKey: projectID)
        }

        for project in activeProjects {
            let normalizedPath = normalizePath(project.localPath)
            if let existing = watchEntries[project.id], existing.rootPath == normalizedPath {
                continue
            }

            watchEntries[project.id]?.watcher.stop()

            let watcher = FileSystemEventWatcher(rootPath: normalizedPath) { [weak self] changedPaths in
                Task { @MainActor in
                    self?.handleEvent(projectID: project.id, changedPaths: changedPaths)
                }
            }

            if watcher.start() {
                watchEntries[project.id] = WatchEntry(rootPath: normalizedPath, watcher: watcher)
            }
        }
    }

    private func handleEvent(projectID: UUID, changedPaths: [String]) {
        guard
            let projectStore,
            let syncManager,
            let project = projectStore.project(for: projectID),
            project.autoSync
        else {
            return
        }

        guard hasMeaningfulChange(changedPaths: changedPaths, project: project) else {
            return
        }

        let now = Date()
        if let lastTriggered = lastTriggeredAtByProject[projectID], now.timeIntervalSince(lastTriggered) < debounceInterval {
            return
        }

        lastTriggeredAtByProject[projectID] = now
        syncManager.enqueueSync(for: project, reason: "文件系统事件触发", triggerKind: .automatic)
    }

    private func hasMeaningfulChange(changedPaths: [String], project: Project) -> Bool {
        if changedPaths.isEmpty {
            return true
        }

        let rules = project.excludes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return changedPaths.contains { path in
            !isIgnored(path: path, projectRoot: project.localPath, rules: rules)
        }
    }

    private func isIgnored(path: String, projectRoot: String, rules: [String]) -> Bool {
        let normalizedRoot = normalizePath(projectRoot)
        let normalizedPath = normalizePath(path)

        let relative: String
        if normalizedPath.hasPrefix(normalizedRoot + "/") {
            relative = String(normalizedPath.dropFirst(normalizedRoot.count + 1))
        } else if normalizedPath == normalizedRoot {
            relative = ""
        } else {
            relative = normalizedPath
        }

        guard !relative.isEmpty else {
            return false
        }

        for rule in rules {
            if relative == rule || relative.hasPrefix(rule + "/") || relative.contains("/" + rule + "/") {
                return true
            }
        }

        return false
    }

    private func isValidDirectory(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
