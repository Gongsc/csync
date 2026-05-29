import Foundation

enum ConflictResolution: String {
    case localOverride
    case remoteOverride
    case skip
}

enum ConflictHandlingMode: String, Codable, CaseIterable {
    case askEveryTime
    case localOverride
    case remoteOverride

    var displayName: String {
        switch self {
        case .askEveryTime:
            return "每次询问"
        case .localOverride:
            return "本地覆盖远端"
        case .remoteOverride:
            return "远端覆盖本地"
        }
    }

    var automaticDecision: ConflictResolution? {
        switch self {
        case .askEveryTime:
            return nil
        case .localOverride:
            return .localOverride
        case .remoteOverride:
            return .remoteOverride
        }
    }
}

struct FileFingerprint: Codable, Equatable {
    let modifiedAt: TimeInterval
    let size: UInt64
}

final class ConflictResolutionRequest: Identifiable {
    let id = UUID()
    let project: Project
    let conflictingFiles: [String]

    private let completion: (ConflictResolution) -> Void
    private let lock = NSLock()
    private var isResolved = false

    init(project: Project, conflictingFiles: [String], completion: @escaping (ConflictResolution) -> Void) {
        self.project = project
        self.conflictingFiles = conflictingFiles
        self.completion = completion
    }

    func resolve(_ decision: ConflictResolution) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return }
        isResolved = true
        completion(decision)
    }
}
