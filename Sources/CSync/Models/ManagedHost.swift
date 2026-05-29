import Foundation

struct ManagedHost: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var address: String
    var username: String
    var encryptedPassword: String?
    var prefersPasswordAuth: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        username: String,
        encryptedPassword: String? = nil,
        prefersPasswordAuth: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.encryptedPassword = encryptedPassword
        self.prefersPasswordAuth = prefersPasswordAuth
        self.updatedAt = updatedAt
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return "\(username)@\(address)"
        }
        return trimmedName
    }

    var location: String {
        "\(username)@\(address)"
    }
}

extension ManagedHost {
    static var emptyDraft: ManagedHost {
        ManagedHost(name: "", address: "", username: NSUserName())
    }
}

extension ManagedHost {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case address
        case username
        case encryptedPassword
        case prefersPasswordAuth
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        username = try container.decode(String.self, forKey: .username)
        encryptedPassword = try container.decodeIfPresent(String.self, forKey: .encryptedPassword)
        prefersPasswordAuth = try container.decodeIfPresent(Bool.self, forKey: .prefersPasswordAuth) ?? false
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(address, forKey: .address)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(encryptedPassword, forKey: .encryptedPassword)
        try container.encode(prefersPasswordAuth, forKey: .prefersPasswordAuth)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
