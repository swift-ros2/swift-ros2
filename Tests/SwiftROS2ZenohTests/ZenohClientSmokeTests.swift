import SwiftROS2Transport
import XCTest

@testable import SwiftROS2Zenoh

final class ZenohClientSmokeTests: XCTestCase {
    func testInitializationDoesNotCrash() {
        _ = ZenohClient()
    }

    // A freshly constructed client has no session until `open` is called.
    func testFreshClientIsNotHealthy() {
        XCTAssertFalse(ZenohClient().isSessionHealthy())
    }

    /// Verifies that calling close() on a client that was never opened throws ZenohError.sessionCloseFailed.
    func testDoubleCloseOnFreshClientThrows() throws {
        let client = ZenohClient()
        XCTAssertThrowsError(try client.close()) { error in
            guard let zErr = error as? ZenohError else {
                XCTFail("Expected ZenohError, got \(type(of: error))")
                return
            }
            if case .sessionCloseFailed = zErr {
                // Correct: closing a never-opened client is reported as sessionCloseFailed.
            } else {
                XCTFail("Expected .sessionCloseFailed, got \(zErr)")
            }
        }
    }
}
