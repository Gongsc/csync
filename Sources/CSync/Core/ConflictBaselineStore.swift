import Foundation

final class ConflictBaselineStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "csync.conflict-baseline-store")
    private let baseURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.baseURL = appSupport
            .appendingPathComponent("CSync", isDirectory: true)
            .appendingPathComponent("conflict-baselines", isDirectory: true)
    }

    func load(projectID: UUID) -> [String: FileFingerprint] {
        queue.sync {
            let url = baselineURL(for: projectID)
            guard fileManager.fileExists(atPath: url.path) else { return [:] }

            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([String: FileFingerprint].self, from: data)
            } catch {
                NSLog("[CSync] 读取冲突基线失败: \(error.localizedDescription)")
                return [:]
            }
        }
    }

    func save(snapshot: [String: FileFingerprint], for projectID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ensureDirectory()
                let url = self.baselineURL(for: projectID)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[CSync] 写入冲突基线失败: \(error.localizedDescription)")
            }
        }
    }

    private func baselineURL(for projectID: UUID) -> URL {
        baseURL.appendingPathComponent("\(projectID.uuidString).json")
    }

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: baseURL.path) {
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
    }
}
