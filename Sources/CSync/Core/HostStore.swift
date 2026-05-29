import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [ManagedHost] = []

    private let fileManager: FileManager
    private let storageURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storageURL = appSupport
            .appendingPathComponent("CSync", isDirectory: true)
            .appendingPathComponent("hosts.json")
        load()
    }

    func host(for id: UUID?) -> ManagedHost? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    func upsert(_ host: ManagedHost) {
        var value = host
        value.updatedAt = Date()

        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = value
        } else {
            hosts.append(value)
        }

        hosts.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        save()
    }

    func remove(hostID: UUID) {
        hosts.removeAll(where: { $0.id == hostID })
        save()
    }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            hosts = try decoder.decode([ManagedHost].self, from: data)
            hosts.sort { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            hosts = []
            NSLog("[CSync] 加载主机配置失败: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try ensureStorageDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(hosts)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[CSync] 保存主机配置失败: \(error.localizedDescription)")
        }
    }

    private func ensureStorageDirectory() throws {
        let directory = storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
