import Foundation

private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutBuffer.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrBuffer.append(data)
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.lock()
        let out = stdoutBuffer
        let err = stderrBuffer
        lock.unlock()
        return (out, err)
    }
}

enum ConflictDetectionError: LocalizedError {
    case sshUnavailable
    case remoteSnapshotFailed(String)
    case remoteSnapshotTimedOut

    var errorDescription: String? {
        switch self {
        case .sshUnavailable:
            return "未找到 ssh，请确认系统环境。"
        case .remoteSnapshotFailed(let message):
            return "远端快照获取失败：\(message)"
        case .remoteSnapshotTimedOut:
            return "远端快照获取超时，请检查远端目录规模或网络连通性。"
        }
    }
}

final class ConflictDetector: @unchecked Sendable {
    private let sshPath = "/usr/bin/ssh"
    private let remoteSnapshotTimeout: TimeInterval = 45

    func detectConflicts(
        project: Project,
        baseline: [String: FileFingerprint],
        password: String?,
        completion: @escaping @Sendable (Result<[String], ConflictDetectionError>) -> Void
    ) {
        guard !baseline.isEmpty else {
            completion(.success([]))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let excludes = Set(project.excludes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                let local = Self.collectLocalSnapshot(rootPath: project.localPath, excludes: excludes)
                let remote = try self.collectRemoteSnapshot(project: project, excludes: excludes, password: password)
                let conflicts = Self.calculateConflicts(local: local, remote: remote, baseline: baseline)
                DispatchQueue.main.async {
                    completion(.success(conflicts))
                }
            } catch let error as ConflictDetectionError {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.remoteSnapshotFailed(error.localizedDescription)))
                }
            }
        }
    }

    func buildLocalSnapshot(project: Project) -> [String: FileFingerprint] {
        let excludes = Set(project.excludes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return Self.collectLocalSnapshot(rootPath: project.localPath, excludes: excludes)
    }

    private func collectRemoteSnapshot(project: Project, excludes: Set<String>, password: String?) throws -> [String: FileFingerprint] {
        guard FileManager.default.fileExists(atPath: sshPath) else {
            throw ConflictDetectionError.sshUnavailable
        }

        let host = "\(project.remoteUser)@\(project.remoteHost)"
        let command = "cd \(shellQuoted(project.remotePath)) && find . -type f -printf '%P\\t%T@\\t%s\\n'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)

        let authEnvironment: SSHProcessEnvironment
        do {
            authEnvironment = try SSHProcessEnvironment.make(password: password)
        } catch {
            throw ConflictDetectionError.remoteSnapshotFailed(error.localizedDescription)
        }
        defer { authEnvironment.cleanup.run() }

        process.environment = authEnvironment.environment
        let usePasswordAuth = (password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        NSLog("[CSync][ConflictDetector] 远端快照开始 host=\(host), auth=\(usePasswordAuth ? "password" : "publickey")")
        process.arguments = sshArguments(host: host, command: command, usePasswordAuth: usePasswordAuth)

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput

        let collector = StreamCollector()

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collector.appendStdout(data)
        }

        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collector.appendStderr(data)
        }

        try process.run()

        let deadline = Date().addingTimeInterval(remoteSnapshotTimeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.interrupt()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            throw ConflictDetectionError.remoteSnapshotTimedOut
        }

        process.waitUntilExit()

        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = output.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = errorOutput.fileHandleForReading.readDataToEndOfFile()

        collector.appendStdout(remainingStdout)
        collector.appendStderr(remainingStderr)
        let snapshot = collector.snapshot()
        let stdoutData = snapshot.stdout
        let stderrData = snapshot.stderr

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            NSLog("[CSync][ConflictDetector] 远端快照失败 host=\(host), code=\(process.terminationStatus), stderr=\(stderr)")
            throw ConflictDetectionError.remoteSnapshotFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        NSLog("[CSync][ConflictDetector] 远端快照成功 host=\(host)")

        return Self.parseSnapshotLines(stdout, excludes: excludes)
    }

    private func sshArguments(host: String, command: String, usePasswordAuth: Bool) -> [String] {
        var args: [String] = [
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "UseKeychain=no",
            "-o", "AddKeysToAgent=no"
        ]

        if usePasswordAuth {
            args.append(contentsOf: [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "PasswordAuthentication=yes",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "BatchMode=no",
                "-o", "IdentityAgent=none"
            ])
        } else {
            args.append(contentsOf: [
                "-o", "PreferredAuthentications=publickey",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PasswordAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "BatchMode=yes"
            ])
        }

        args.append(host)
        args.append(command)
        return args
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func collectLocalSnapshot(rootPath: String, excludes: Set<String>) -> [String: FileFingerprint] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return [:]
        }

        var snapshot: [String: FileFingerprint] = [:]

        while let fileURL = enumerator.nextObject() as? URL {
            let relativePath = relativePathString(root: rootURL, file: fileURL)
            if shouldExclude(relativePath: relativePath, excludes: excludes) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            guard values.isDirectory != true else { continue }
            guard
                let modifiedDate = values.contentModificationDate,
                let fileSize = values.fileSize
            else {
                continue
            }

            snapshot[relativePath] = FileFingerprint(
                modifiedAt: modifiedDate.timeIntervalSince1970,
                size: UInt64(max(fileSize, 0))
            )
        }

        return snapshot
    }

    private static func parseSnapshotLines(_ text: String, excludes: Set<String>) -> [String: FileFingerprint] {
        var snapshot: [String: FileFingerprint] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }

            let rawPath = String(columns[0])
            if rawPath.isEmpty { continue }
            if shouldExclude(relativePath: rawPath, excludes: excludes) { continue }

            guard let modifiedAt = Double(columns[1]), let size = UInt64(columns[2]) else { continue }
            snapshot[rawPath] = FileFingerprint(modifiedAt: modifiedAt, size: size)
        }

        return snapshot
    }

    private static func calculateConflicts(
        local: [String: FileFingerprint],
        remote: [String: FileFingerprint],
        baseline: [String: FileFingerprint]
    ) -> [String] {
        let allPaths = Set(local.keys).union(remote.keys).union(baseline.keys)

        var conflicts: [String] = []
        conflicts.reserveCapacity(32)

        for path in allPaths {
            let baselineValue = baseline[path]
            let localValue = local[path]
            let remoteValue = remote[path]

            let localChanged = localValue != baselineValue
            let remoteChanged = remoteValue != baselineValue

            if localChanged && remoteChanged && localValue != remoteValue {
                conflicts.append(path)
            }
        }

        return conflicts.sorted()
    }

    private static func shouldExclude(relativePath: String, excludes: Set<String>) -> Bool {
        if relativePath.isEmpty { return false }

        for rule in excludes where !rule.isEmpty {
            if relativePath == rule || relativePath.hasPrefix("\(rule)/") {
                return true
            }
            if relativePath.contains("/\(rule)/") {
                return true
            }
        }

        return false
    }

    private static func relativePathString(root: URL, file: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = file.path
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count))
        }
        return file.lastPathComponent
    }
}
