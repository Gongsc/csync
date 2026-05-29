import Foundation

private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var combinedLines: [String] = []
    private var errorLines: [String] = []
    private let maxLines = 120
    private let maxCharacters = 6000

    func append(_ newValue: String, isError: Bool) {
        let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        lock.lock()
        combinedLines.append(normalized)
        if combinedLines.count > maxLines {
            combinedLines.removeFirst(combinedLines.count - maxLines)
        }

        if isError {
            errorLines.append(normalized)
            if errorLines.count > maxLines {
                errorLines.removeFirst(errorLines.count - maxLines)
            }
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let preferredLines = errorLines.isEmpty ? combinedLines : errorLines
        lock.unlock()

        if preferredLines.isEmpty {
            return ""
        }

        var text = preferredLines.joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.suffix(maxCharacters))
        }

        return text
    }
}

final class RunningSync {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        if process.isRunning {
            process.terminate()
        }
    }
}

enum SyncDirection {
    case localToRemote
    case remoteToLocal
}

enum SyncExecutionError: LocalizedError {
    case rsyncUnavailable
    case invalidLocalPath(String)
    case launchFailed(String)
    case rsyncFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .rsyncUnavailable:
            return "未找到 rsync，请先安装后重试。"
        case .invalidLocalPath(let path):
            return "本地路径不可用：\(path)"
        case .launchFailed(let message):
            return "同步进程启动失败：\(message)"
        case .rsyncFailed(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "rsync 退出码 \(code)"
            }
            if code == 255, trimmed.localizedCaseInsensitiveContains("Permission denied") {
                return "rsync 退出码 255：SSH 认证失败（请检查用户名、密码与服务器登录策略）。\n\(trimmed)"
            }
            return "rsync 退出码 \(code)：\(trimmed)"
        }
    }
}

final class RsyncExecutor {
    private let parser = RsyncProgressParser()
    private let rsyncPath: String
    private let progressArgument: String

    init() {
        self.rsyncPath = Self.resolveRsyncPath()
        self.progressArgument = Self.resolveProgressArgument(rsyncPath: rsyncPath)
    }

    func startSync(
        project: Project,
        direction: SyncDirection,
        password: String?,
        progress: @escaping @Sendable (Double?, String) -> Void,
        completion: @escaping @Sendable (Result<Void, SyncExecutionError>) -> Void
    ) throws -> RunningSync {
        guard FileManager.default.fileExists(atPath: rsyncPath) else {
            throw SyncExecutionError.rsyncUnavailable
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.localPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncExecutionError.invalidLocalPath(project.localPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)

        let authEnvironment: SSHProcessEnvironment
        do {
            authEnvironment = try SSHProcessEnvironment.make(password: password)
        } catch {
            throw SyncExecutionError.launchFailed(error.localizedDescription)
        }

        process.environment = authEnvironment.environment
        let usePasswordAuth = (password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        NSLog("[CSync][Rsync] 启动同步 project=\(project.name), direction=\(direction == .localToRemote ? "upload" : "download"), auth=\(usePasswordAuth ? "password" : "publickey")")
        process.arguments = makeArguments(project: project, direction: direction, usePasswordAuth: usePasswordAuth)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outputState = OutputState()

        let lineHandler: @Sendable (Data, Bool) -> Void = { [parser] data, isError in
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(whereSeparator: \.isNewline)
            for rawLine in lines {
                let line = String(rawLine)
                guard !line.isEmpty else { continue }
                outputState.append(line, isError: isError)
                progress(parser.progress(from: line), line)
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            lineHandler(handle.availableData, false)
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            lineHandler(handle.availableData, true)
        }

        process.terminationHandler = { process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            authEnvironment.cleanup.run()
            let output = outputState.snapshot()

            if process.terminationStatus == 0 {
                completion(.success(()))
            } else {
                completion(.failure(.rsyncFailed(code: process.terminationStatus, message: output)))
            }
        }

        do {
            try process.run()
        } catch {
            authEnvironment.cleanup.run()
            throw SyncExecutionError.launchFailed(error.localizedDescription)
        }

        return RunningSync(process: process)
    }

    private func makeArguments(project: Project, direction: SyncDirection, usePasswordAuth: Bool) -> [String] {
        var arguments: [String] = [
            "-az",
            "--delete",
            "--partial",
            "--human-readable",
            progressArgument
        ]

        arguments.append(contentsOf: ["-e", sshCommand(usePasswordAuth: usePasswordAuth)])

        for pattern in project.excludes where !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--exclude", pattern])
        }

        let normalizedLocalPath = project.localPath.hasSuffix("/") ? project.localPath : "\(project.localPath)/"
        let normalizedRemotePath = project.remoteLocation.hasSuffix("/") ? project.remoteLocation : "\(project.remoteLocation)/"

        switch direction {
        case .localToRemote:
            arguments.append(normalizedLocalPath)
            arguments.append(normalizedRemotePath)
        case .remoteToLocal:
            arguments.append(normalizedRemotePath)
            arguments.append(normalizedLocalPath)
        }

        return arguments
    }

    private func sshCommand(usePasswordAuth: Bool) -> String {
        var options: [String] = [
            "ssh",
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "UseKeychain=no",
            "-o", "AddKeysToAgent=no"
        ]

        if usePasswordAuth {
            options.append(contentsOf: [
                "-F", "/dev/null",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "PasswordAuthentication=yes",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "BatchMode=no",
                "-o", "IdentityAgent=none"
            ])
        } else {
            options.append(contentsOf: [
                "-o", "PreferredAuthentications=publickey",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PasswordAuthentication=no",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "BatchMode=yes"
            ])
        }

        return options.joined(separator: " ")
    }

    private static func resolveRsyncPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/rsync",
            "/usr/local/bin/rsync",
            "/usr/bin/rsync"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return "/usr/bin/rsync"
    }

    private static func resolveProgressArgument(rsyncPath: String) -> String {
        guard let version = rsyncVersion(rsyncPath: rsyncPath) else {
            return "--progress"
        }

        let major = version.major
        if major >= 3 {
            return "--info=progress2"
        }

        return "--progress"
    }

    private static func rsyncVersion(rsyncPath: String) -> (major: Int, minor: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)
        process.arguments = ["--version"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard
            let regex = try? NSRegularExpression(pattern: #"rsync\s+version\s+(\d+)\.(\d+)"#, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges >= 3,
            let majorRange = Range(match.range(at: 1), in: text),
            let minorRange = Range(match.range(at: 2), in: text),
            let major = Int(text[majorRange]),
            let minor = Int(text[minorRange])
        else {
            return nil
        }

        return (major, minor)
    }
}
