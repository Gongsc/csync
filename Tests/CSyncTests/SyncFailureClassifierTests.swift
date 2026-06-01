import XCTest
@testable import CSync

final class SyncFailureClassifierTests: XCTestCase {
    func testTransientNetworkFailureIsRetryable() {
        let message = "rsync: connection timed out after 10000 milliseconds"
        XCTAssertTrue(SyncFailureClassifier.isLikelyTransientNetworkFailure(message: message))
    }

    func testAuthenticationFailureIsNotRetryable() {
        let message = "Permission denied (publickey,password)."
        XCTAssertFalse(SyncFailureClassifier.isLikelyTransientNetworkFailure(message: message))
    }

    func testUnknownFailureIsNotRetryable() {
        let message = "rsync exited with code 23"
        XCTAssertFalse(SyncFailureClassifier.isLikelyTransientNetworkFailure(message: message))
    }
}
