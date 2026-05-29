import Foundation

enum FileSnapshot {
    private static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData"
    ]

    static func latestModificationDate(atPath path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return nil
        }

        var latest: Date = .distantPast

        while let item = enumerator.nextObject() as? URL {
            if shouldSkip(url: item) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if let date = values.contentModificationDate, date > latest {
                latest = date
            }
        }

        return latest == .distantPast ? nil : latest
    }

    private static func shouldSkip(url: URL) -> Bool {
        ignoredDirectories.contains(url.lastPathComponent)
    }
}
