import Foundation

struct RuntimeEnvironmentStatus {
    let checkedAt: Date
    let rsyncPath: String?
    let sshPath: String?
    let issues: [String]

    var isHealthy: Bool {
        issues.isEmpty
    }
}

final class RuntimeEnvironmentChecker {
    func check() -> RuntimeEnvironmentStatus {
        var issues: [String] = []

        let rsyncPath = resolveExecutable(candidates: [
            "/opt/homebrew/bin/rsync",
            "/usr/local/bin/rsync",
            "/usr/bin/rsync"
        ])

        let sshPath = resolveExecutable(candidates: [
            "/usr/bin/ssh",
            "/opt/homebrew/bin/ssh",
            "/usr/local/bin/ssh"
        ])

        if rsyncPath == nil {
            issues.append("未检测到可执行 rsync，请先安装或加入 PATH。")
        }

        if sshPath == nil {
            issues.append("未检测到可执行 ssh，请检查系统环境。")
        }

        return RuntimeEnvironmentStatus(
            checkedAt: Date(),
            rsyncPath: rsyncPath,
            sshPath: sshPath,
            issues: issues
        )
    }

    private func resolveExecutable(candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
