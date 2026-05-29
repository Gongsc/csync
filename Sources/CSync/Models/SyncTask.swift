import Foundation

enum SyncTriggerKind: String, Equatable {
    case manual
    case automatic

    var shortLabel: String {
        switch self {
        case .manual:
            return "手动"
        case .automatic:
            return "自动"
        }
    }
}

enum SyncFileStatus: String, Equatable {
    case succeeded
    case failed
}

struct SyncFileResult: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let status: SyncFileStatus
}

enum SyncTaskState: Equatable {
    case queued(reason: String)
    case running(progress: Double, message: String)
    case succeeded(Date)
    case failed(String)
    case cancelled
}

struct SyncTask: Identifiable, Equatable {
    let id: UUID
    let projectID: UUID
    var projectName: String
    var state: SyncTaskState
    var triggerKind: SyncTriggerKind
    var fileResults: [SyncFileResult]
    var updatedAt: Date

    init(
        projectID: UUID,
        projectName: String,
        state: SyncTaskState,
        triggerKind: SyncTriggerKind,
        fileResults: [SyncFileResult] = [],
        updatedAt: Date = Date()
    ) {
        self.id = projectID
        self.projectID = projectID
        self.projectName = projectName
        self.state = state
        self.triggerKind = triggerKind
        self.fileResults = fileResults
        self.updatedAt = updatedAt
    }

    var runningModeText: String {
        switch triggerKind {
        case .manual:
            return "手动同步进行中"
        case .automatic:
            return "自动同步进行中"
        }
    }

    var queuedModeText: String {
        switch triggerKind {
        case .manual:
            return "手动同步排队中"
        case .automatic:
            return "自动同步排队中"
        }
    }

    var modeBadgeText: String {
        triggerKind.shortLabel
    }
}

extension SyncTaskState {
    var summaryText: String {
        switch self {
        case .queued(let reason):
            return "排队中 · \(reason)"
        case .running(let progress, let message):
            return "同步中 \(Int(progress * 100))% · \(message)"
        case .succeeded(let date):
            return "成功 · \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message):
            return "失败 · \(message)"
        case .cancelled:
            return "已取消"
        }
    }

    var progressValue: Double? {
        if case .running(let progress, _) = self {
            return progress
        }
        return nil
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var isQueued: Bool {
        if case .queued = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
