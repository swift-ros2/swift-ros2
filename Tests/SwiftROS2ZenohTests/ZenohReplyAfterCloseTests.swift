import Foundation
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2Transport
@testable import SwiftROS2Zenoh

/// A reply made after its queryable was closed must throw, not reach the C
/// bridge: undeclaring a queryable frees every query it still holds. Requires
/// `ZENOH_ROUTER` (for example `tcp/192.168.1.85:7447`). Skips otherwise.
///
/// The failure these tests guard against is a heap-use-after-free, so they are
/// most telling under AddressSanitizer (`swift test --sanitize=address` with
/// `ASAN_OPTIONS=detect_leaks=0`).
final class ZenohReplyAfterCloseTests: XCTestCase {
    private func router() throws -> String {
        guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
            throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
        }
        return router
    }

    /// Declares a queryable on `server` whose handler keeps the query without
    /// replying, and asks from `asker` until one query is held.
    private func holdQuery(
        on server: ZenohClient, asker: ZenohClient, keyExpr: String
    ) async throws -> (queryable: any ZenohQueryableHandle, query: any ZenohQueryHandle) {
        let held = Box<[any ZenohQueryHandle]>([])
        let queryable = try server.declareQueryable(keyExpr) { query in
            held.append(query)
        }
        // The router learns about the new queryable asynchronously, so a get
        // issued right away can come back empty; keep asking.
        let arrived = await eventually(interval: .milliseconds(200)) {
            if !held.value.isEmpty { return true }
            try? asker.get(
                keyExpr: keyExpr, payload: nil, attachment: nil, timeoutMs: 1_000,
                handler: { _ in }, onFinish: {})
            return false
        }
        guard arrived, let query = held.value.first else {
            try? queryable.close()
            throw XCTSkip("no query reached the queryable on \(keyExpr)")
        }
        return (queryable, query)
    }

    private func openPair() throws -> (server: ZenohClient, asker: ZenohClient) {
        let locator = try router()
        let server = ZenohClient()
        try server.open(locator: locator)
        let asker = ZenohClient()
        try asker.open(locator: locator)
        return (server, asker)
    }

    func testReplyAfterQueryableCloseThrows() async throws {
        let (server, asker) = try openPair()
        defer {
            try? asker.close()
            try? server.close()
        }
        let (queryable, query) = try await holdQuery(
            on: server, asker: asker, keyExpr: "swift_reply_after_close/queryable")

        try queryable.close()

        XCTAssertThrowsError(try query.reply(payload: Data([0x01]), attachment: nil))
    }

    func testReplyErrorAfterQueryableCloseThrows() async throws {
        let (server, asker) = try openPair()
        defer {
            try? asker.close()
            try? server.close()
        }
        let (queryable, query) = try await holdQuery(
            on: server, asker: asker, keyExpr: "swift_reply_after_close/queryable_err")

        try queryable.close()

        XCTAssertThrowsError(try query.replyError(message: "late"))
    }

    /// Closing the session closes its queryables first, so a held query is
    /// invalid afterwards too.
    func testReplyAfterSessionCloseThrows() async throws {
        let (server, asker) = try openPair()
        defer { try? asker.close() }
        let (_, query) = try await holdQuery(
            on: server, asker: asker, keyExpr: "swift_reply_after_close/session")

        try server.close()

        XCTAssertThrowsError(try query.reply(payload: Data([0x01]), attachment: nil))
    }

    /// A query that was answered before the close stays consumed, and the
    /// close does not touch it again.
    func testCloseAfterReplyIsClean() async throws {
        let (server, asker) = try openPair()
        defer {
            try? asker.close()
            try? server.close()
        }
        let (queryable, query) = try await holdQuery(
            on: server, asker: asker, keyExpr: "swift_reply_after_close/replied")

        try query.reply(payload: Data([0x01]), attachment: nil)
        XCTAssertEqual((queryable as? ZenohQueryable)?.outstandingQueryCount, 0)
        try queryable.close()

        XCTAssertThrowsError(try query.reply(payload: Data([0x02]), attachment: nil))
    }

    /// A handle nobody replied to and nobody holds any more leaves the list,
    /// and the close still frees its query.
    func testCloseAfterHandleWasReleased() async throws {
        let (server, asker) = try openPair()
        defer {
            try? asker.close()
            try? server.close()
        }
        let keyExpr = "swift_reply_after_close/released"
        let seen = Box(0)
        let queryable = try XCTUnwrap(
            try server.declareQueryable(keyExpr) { _ in seen.mutate { $0 += 1 } } as? ZenohQueryable)
        let arrived = await eventually(interval: .milliseconds(200)) {
            if seen.value > 0 { return true }
            try? asker.get(
                keyExpr: keyExpr, payload: nil, attachment: nil, timeoutMs: 1_000,
                handler: { _ in }, onFinish: {})
            return false
        }
        try XCTSkipUnless(arrived, "no query reached the queryable on \(keyExpr)")

        XCTAssertEqual(queryable.outstandingQueryCount, 0)
        try queryable.close()
    }

    /// The reply and the close run on two threads at once: whichever comes
    /// first, the reply either goes out or throws, and nothing is freed under
    /// a reply in progress.
    func testReplyRacingQueryableClose() async throws {
        let (server, asker) = try openPair()
        defer {
            try? asker.close()
            try? server.close()
        }
        for round in 0..<20 {
            let (queryable, query) = try await holdQuery(
                on: server, asker: asker, keyExpr: "swift_reply_after_close/race/\(round)")
            let start = DispatchSemaphore(value: 0)
            let done = DispatchGroup()
            DispatchQueue.global().async(group: done) {
                start.wait()
                try? query.reply(payload: Data(repeating: 0x5A, count: 64), attachment: Data([0x01]))
            }
            DispatchQueue.global().async(group: done) {
                start.wait()
                try? queryable.close()
            }
            start.signal()
            start.signal()
            await withCheckedContinuation { continuation in
                done.notify(queue: .global()) { continuation.resume() }
            }
            XCTAssertThrowsError(try query.reply(payload: Data([0x01]), attachment: nil), "round \(round)")
        }
    }
}
