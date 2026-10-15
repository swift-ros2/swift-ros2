import XCTest

@testable import SwiftROS2Transport

final class TransportErrorTests: XCTestCase {
    func testRecoverableErrorsAreTheOnesThatMaySucceedOnRetry() {
        XCTAssertTrue(TransportError.connectionFailed("x").isRecoverable)
        XCTAssertTrue(TransportError.publishFailed("x").isRecoverable)
        XCTAssertTrue(TransportError.sessionUnhealthy("x").isRecoverable)
        // Discovery of an action server may succeed later.
        XCTAssertTrue(TransportError.actionServerUnavailable.isRecoverable)
        // Retrying cannot fix a bad configuration or an unsupported feature.
        XCTAssertFalse(TransportError.invalidConfiguration("x").isRecoverable)
        XCTAssertFalse(TransportError.unsupportedFeature("x").isRecoverable)
    }
}
