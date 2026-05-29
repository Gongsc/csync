import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var hostID: UUID?
    var name: String
    var localPath: String
    var remoteHost: String
    var remotePath: String
    var remoteUser: String
    var usePasswordAuth: Bool = false
    var conflictHandlingMode: ConflictHandlingMode? = .askEveryTime
    var autoSync: Bool
    var excludes: [String]
    var lastSyncedAt: Date?

    init(
        id: UUID = UUID(),
        hostID: UUID? = nil,
        name: String,
        localPath: String,
        remoteHost: String,
        remotePath: String,
        remoteUser: String,
        usePasswordAuth: Bool = false,
        conflictHandlingMode: ConflictHandlingMode? = .askEveryTime,
        autoSync: Bool = true,
        excludes: [String] = [".git", "node_modules", ".build", "DerivedData"],
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.localPath = localPath
        self.remoteHost = remoteHost
        self.remotePath = remotePath
        self.remoteUser = remoteUser
        self.usePasswordAuth = usePasswordAuth
        self.conflictHandlingMode = conflictHandlingMode
        self.autoSync = autoSync
        self.excludes = excludes
        self.lastSyncedAt = lastSyncedAt
    }
}

extension Project {
    static var emptyDraft: Project {
        Project(
            name: "",
            localPath: "",
            remoteHost: "",
            remotePath: "",
            remoteUser: NSUserName(),
            usePasswordAuth: false,
            conflictHandlingMode: .askEveryTime,
            autoSync: true
        )
    }

    var remoteLocation: String {
        "\(remoteUser)@\(remoteHost):\(remotePath)"
    }
}
