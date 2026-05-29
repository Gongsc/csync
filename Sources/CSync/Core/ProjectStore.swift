import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    private let fileManager: FileManager
    private let storageURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storageURL = appSupport
            .appendingPathComponent("CSync", isDirectory: true)
            .appendingPathComponent("projects.json")
        load()
    }

    func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first(where: { $0.id == id })
    }

    func upsert(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        save()
    }

    func remove(projectID: UUID) {
        projects.removeAll(where: { $0.id == projectID })
        save()
    }

    func markSynced(projectID: UUID, at date: Date) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].lastSyncedAt = date
        save()
    }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            projects = try decoder.decode([Project].self, from: data)
        } catch {
            projects = []
            NSLog("[CSync] 加载项目配置失败: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try ensureStorageDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(projects)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[CSync] 保存项目配置失败: \(error.localizedDescription)")
        }
    }

    private func ensureStorageDirectory() throws {
        let directory = storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
