import Foundation

enum SyncFailureClassifier {
    static func isAuthenticationFailure(message: String) -> Bool {
        let text = message.lowercased()
        let authHints = [
            "permission denied",
            "authentication failed",
            "auth fail",
            "publickey",
            "password",
            "access denied",
            "denied (publickey",
            "host key verification failed"
        ]

        return authHints.contains { text.contains($0) }
    }

    static func isLikelyTransientNetworkFailure(message: String) -> Bool {
        let text = message.lowercased()

        if isAuthenticationFailure(message: text) {
            return false
        }

        let transientHints = [
            "connection timed out",
            "operation timed out",
            "timed out",
            "connection reset",
            "connection refused",
            "network is unreachable",
            "no route to host",
            "broken pipe",
            "software caused connection abort",
            "resource temporarily unavailable",
            "temporary failure",
            "connection closed",
            "failed to connect"
        ]

        return transientHints.contains { text.contains($0) }
    }
}
