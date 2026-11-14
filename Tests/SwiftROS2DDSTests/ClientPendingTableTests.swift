// ClientPendingTableTests.swift
// Insert / resolve / cancel / failAll behaviors of the per-client correlation table.

import Foundation
import XCTest

@testable import SwiftROS2Transport

final class ClientPendingTableTests: XCTestCase {
    func testInsertAndResolve() async throws {
        let table = ClientPendingTable()
        async let pending: Data = table.insert(seq: 1) { _ in }  // resolved externally
        try await Task.sleep(nanoseconds: 10_000_000)
        let didResolve = await table.resolve(seq: 1, with: .success(Data([0x01])))
        XCTAssertTrue(didResolve)
        let value = try await pending
        XCTAssertEqual(value, Data([0x01]))
    }

    func testResolveByOtherCaller() async throws {
        let table = ClientPendingTable()
        async let pending: Data = table.insert(seq: 7) { _ in }  // resolved externally
        try await Task.sleep(nanoseconds: 10_000_000)
        let didResolve = await table.resolve(seq: 7, with: .success(Data([0xAA])))
        XCTAssertTrue(didResolve)
        let value = try await pending
        XCTAssertEqual(value, Data([0xAA]))
    }

    func testResolveUnknownSeqIsNoOp() async {
        let table = ClientPendingTable()
        let didResolve = await table.resolve(seq: 999, with: .success(Data()))
        XCTAssertFalse(didResolve)
    }

    func testFailAllResolvesAllPending() async throws {
        let table = ClientPendingTable()
        async let a: Data = table.insert(seq: 1) { _ in }
        async let b: Data = table.insert(seq: 2) { _ in }
        try await Task.sleep(nanoseconds: 10_000_000)
        await table.failAll(TransportError.sessionClosed)
        do {
            _ = try await a
            XCTFail("should throw")
        } catch {}
        do {
            _ = try await b
            XCTFail("should throw")
        } catch {}
    }

    // MARK: - awaitReply

    /// Runs `awaitReply` in its own task and returns how it ended. When it has
    /// not finished after `limit`, fails the test and unblocks it with
    /// `failAll` so a regression shows up as a failure instead of a hang.
    private func awaitReplyOutcome(
        table: ClientPendingTable,
        limit: Duration = .seconds(5),
        _ call: @escaping @Sendable () async throws -> Data
    ) async -> Result<Data, Error> {
        let task = Task { () -> Result<Data, Error> in
            do {
                return .success(try await call())
            } catch {
                return .failure(error)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: limit)
        let watchdog = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled {
                await table.failAll(TransportError.sessionClosed)
            }
        }
        let outcome = await task.value
        watchdog.cancel()
        if case .failure(let error) = outcome, case TransportError.sessionClosed = error {
            XCTFail("awaitReply did not finish within \(limit)")
        }
        return outcome
    }

    func testAwaitReplyTimesOutWhenTimeoutFiresImmediately() async {
        // A zero timeout used to fire before the continuation was registered;
        // the call then found nothing to resolve and waited forever.
        let table = ClientPendingTable()
        for seq in Int64(1)...50 {
            let outcome = await awaitReplyOutcome(table: table) {
                try await table.awaitReply(seq: seq, timeout: .zero) {}
            }
            guard case .failure(let error) = outcome, case TransportError.requestTimeout = error else {
                XCTFail("seq \(seq): expected requestTimeout, got \(outcome)")
                return
            }
        }
    }

    func testAwaitReplyFromCancelledTaskThrowsCancelledWithoutSending() async {
        // `onCancel` runs before the continuation exists when the task is
        // already cancelled; the call must still end with requestCancelled.
        let table = ClientPendingTable()
        let sent = SendCounter()
        let outcome = await awaitReplyOutcome(table: table) {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await table.awaitReply(seq: 1, timeout: .seconds(Int.max)) {
                sent.increment()
            }
        }
        guard case .failure(let error) = outcome, case TransportError.requestCancelled = error else {
            XCTFail("expected requestCancelled, got \(outcome)")
            return
        }
        XCTAssertEqual(sent.value, 0)
    }

    func testAwaitReplyReturnsReply() async throws {
        let table = ClientPendingTable()
        let outcome = await awaitReplyOutcome(table: table) {
            try await table.awaitReply(seq: 3, timeout: .seconds(5)) {
                Task { await table.resolve(seq: 3, with: .success(Data([0x2A]))) }
            }
        }
        XCTAssertEqual(try outcome.get(), Data([0x2A]))
    }

    func testAwaitReplySurfacesSendError() async {
        struct SendFailed: Error {}
        let table = ClientPendingTable()
        let outcome = await awaitReplyOutcome(table: table) {
            try await table.awaitReply(seq: 4, timeout: .seconds(5)) { throw SendFailed() }
        }
        guard case .failure(let error) = outcome, error is SendFailed else {
            XCTFail("expected SendFailed, got \(outcome)")
            return
        }
    }
}

private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
