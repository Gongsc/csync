import Foundation
import CryptoKit

@MainActor
final class HostPasswordCipher {
    static let shared = HostPasswordCipher()

    private let key: SymmetricKey

    private init() {
        let keySeed = [
            Bundle.main.bundleIdentifier ?? "com.gongsc.CSync",
            ProcessInfo.processInfo.hostName,
            NSUserName(),
            "host-password-cipher-v1"
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(keySeed.utf8))
        key = SymmetricKey(data: Data(digest))
    }

    func encrypt(_ password: String) -> String? {
        let normalized = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        do {
            let payload = Data(normalized.utf8)
            let sealedBox = try AES.GCM.seal(payload, using: key)
            guard let combined = sealedBox.combined else { return nil }
            return combined.base64EncodedString()
        } catch {
            NSLog("[CSync][HostPasswordCipher] 密码加密失败: \(error.localizedDescription)")
            return nil
        }
    }

    func decrypt(_ encryptedPassword: String) -> String? {
        guard let payload = Data(base64Encoded: encryptedPassword) else {
            NSLog("[CSync][HostPasswordCipher] 密码解密失败: 非法base64")
            return nil
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: payload)
            let data = try AES.GCM.open(sealedBox, using: key)
            return String(data: data, encoding: .utf8)
        } catch {
            NSLog("[CSync][HostPasswordCipher] 密码解密失败: \(error.localizedDescription)")
            return nil
        }
    }
}
