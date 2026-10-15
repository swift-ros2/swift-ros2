import Foundation
import XCTest

@testable import SwiftROS2Transport
@testable import SwiftROS2Zenoh

/// Exercises `declareQueryable` + `get` against a live Zenoh router. Requires
/// `ZENOH_ROUTER` (for example `tcp/192.168.1.85:7447`). Skips otherwise.
final class ZenohQueryableSmokeTests: XCTestCase {
    func testDeclareReplyUndeclare() async throws {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }

        // The queryable and the get live on two sessions: the get reaches the queryable through the router.
        let z = ZenohClient()
        try z.open(locator: router)
        defer { try? z.close() }
        let asker = ZenohClient()
        try asker.open(locator: router)
        defer { try? asker.close() }

        let queryable = try z.declareQueryable("swift_srv_smoke/echo") { query in
            try? query.reply(payload: Data([0x01, 0x02]), attachment: nil)
        }

        // The router learns about the new queryable asynchronously, so a get issued right away can come
        // back empty; keep asking until the reply arrives.
        let exp = expectation(description: "reply")
        exp.assertForOverFulfill = false
        let asking = Task {
            while !Task.isCancelled {
                try asker.get(
                    keyExpr: "swift_srv_smoke/echo",
                    payload: nil,
                    attachment: nil,
                    timeoutMs: 1_000,
                    handler: { result in
                        if case .success(let sample) = result, sample.payload == Data([0x01, 0x02]) {
                            exp.fulfill()
                        }
                    },
                    onFinish: {}
                )
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        await fulfillment(of: [exp], timeout: 20)
        asking.cancel()
        try queryable.close()
    }
}
