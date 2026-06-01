import Foundation

struct DiagnosticLogEntry: Codable {
    let timestamp: Date
    let level: String
    let category: String
    let message: String
    let metadata: [String: String]
}

final class DiagnosticsStore {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let logsDirectoryURL: URL
    private let logFileURL: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        logsDirectoryURL = appSupport.appendingPathComponent("CSync/Diagnostics", isDirectory: true)
        logFileURL = logsDirectoryURL.appendingPathComponent("sync-events.jsonl")

        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        encoder = jsonEncoder

        createDirectoryIfNeeded()
    }

    func append(level: String, category: String, message: String, metadata: [String: String] = [:]) {
        let entry = DiagnosticLogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            metadata: metadata
        )

        guard let data = try? encoder.encode(entry) else { return }
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            return
        }
    }

    func exportSnapshot() -> URL? {
        guard fileManager.fileExists(atPath: logFileURL.path) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let exportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("csync-diagnostics-\(stamp).jsonl")

        do {
            if fileManager.fileExists(atPath: exportURL.path) {
                try fileManager.removeItem(at: exportURL)
            }
            try fileManager.copyItem(at: logFileURL, to: exportURL)
            return exportURL
        } catch {
            return nil
        }
    }

    private func createDirectoryIfNeeded() {
        if fileManager.fileExists(atPath: logsDirectoryURL.path) { return }
        try? fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
    }
}
