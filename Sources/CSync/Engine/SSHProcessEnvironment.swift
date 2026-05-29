import Foundation

enum SSHProcessEnvironmentError: LocalizedError {
    case createScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .createScriptFailed(let message):
            return "创建 SSH 密码注入脚本失败：\(message)"
        }
    }
}

final class CleanupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanup: (() -> Void)?

    init(cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    func run() {
        lock.lock()
        let action = cleanup
        cleanup = nil
        lock.unlock()
        action?()
    }
}

struct SSHProcessEnvironment {
    let environment: [String: String]
    let cleanup: CleanupBox

    static func make(password: String?) throws -> SSHProcessEnvironment {
        let base = ProcessInfo.processInfo.environment

        guard let password, !password.isEmpty else {
            return SSHProcessEnvironment(environment: base, cleanup: CleanupBox(cleanup: {}))
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("csync-askpass-\(UUID().uuidString).sh")

        let escaped = password.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = "#!/bin/sh\nprintf '%s' '\(escaped)'\n"

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw SSHProcessEnvironmentError.createScriptFailed(error.localizedDescription)
        }

        var env = base
        env["SSH_ASKPASS"] = scriptURL.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? "localhost:0"

        let cleanup = CleanupBox {
            try? fm.removeItem(at: scriptURL)
        }

        return SSHProcessEnvironment(environment: env, cleanup: cleanup)
    }
}
