import Foundation

enum HostConnectionTestError: LocalizedError {
    case launchFailed(String)
    case commandFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "测试进程启动失败：\(message)"
        case .commandFailed(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "连接测试失败，退出码 \(code)"
            }
            return "连接测试失败，退出码 \(code)：\(trimmed)"
        }
    }
}

final class HostConnectionTester {
    func test(
        host: ManagedHost,
        password: String?,
        completion: @escaping (Result<String, HostConnectionTestError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

            let authEnvironment: SSHProcessEnvironment
            do {
                authEnvironment = try SSHProcessEnvironment.make(password: password)
            } catch {
                completion(.failure(.launchFailed(error.localizedDescription)))
                return
            }

            process.environment = authEnvironment.environment

            let usePasswordAuth = (password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            NSLog("[CSync][HostTest] 开始连接测试 host=\(host.location), auth=\(usePasswordAuth ? "password" : "publickey")")

            var arguments: [String] = [
                "-F", "/dev/null",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=8",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=1",
                "-o", "UseKeychain=no",
                "-o", "AddKeysToAgent=no"
            ]

            if usePasswordAuth {
                arguments.append(contentsOf: [
                    "-o", "PreferredAuthentications=keyboard-interactive,password",
                    "-o", "KbdInteractiveAuthentication=yes",
                    "-o", "PasswordAuthentication=yes",
                    "-o", "PubkeyAuthentication=no",
                    "-o", "NumberOfPasswordPrompts=1",
                    "-o", "BatchMode=no",
                    "-o", "IdentityAgent=none"
                ])
            } else {
                arguments.append(contentsOf: [
                    "-o", "PreferredAuthentications=publickey",
                    "-o", "KbdInteractiveAuthentication=no",
                    "-o", "PasswordAuthentication=no",
                    "-o", "NumberOfPasswordPrompts=0",
                    "-o", "BatchMode=yes"
                ])
            }

            arguments.append(host.location)
            arguments.append("printf '__CSYNC_OK__'")
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                authEnvironment.cleanup.run()
                completion(.failure(.launchFailed(error.localizedDescription)))
                return
            }

            process.waitUntilExit()
            authEnvironment.cleanup.run()

            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = [stdoutText, stderrText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            if process.terminationStatus == 0, stdoutText.contains("__CSYNC_OK__") {
                NSLog("[CSync][HostTest] 测试成功 host=\(host.location)")
                let detail = combined.isEmpty ? "连接成功" : "连接成功\n\(combined)"
                completion(.success(detail))
                return
            }

            NSLog("[CSync][HostTest] 测试失败 host=\(host.location), code=\(process.terminationStatus), message=\(combined)")
            completion(.failure(.commandFailed(code: process.terminationStatus, message: combined)))
        }
    }
}
