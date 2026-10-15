// ActionCancelGoalTests.swift
// CancelGoal semantics of ROS2ActionServer, mirroring rcl_action's
// `rcl_action_process_cancel_request`: only goals that are still cancelable
// (ACCEPTED or EXECUTING) are canceled; terminal goals are skipped.

import Foundation
import SwiftROS2ExampleInterfaces
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

final class ActionCancelGoalTests: XCTestCase {
    // action_msgs/srv/CancelGoal return codes.
    private static let errorNone: Int8 = 0
    private static let errorRejected: Int8 = 1
    private static let errorUnknownGoalId: Int8 = 2
    private static let errorGoalTerminated: Int8 = 3

    private static func goalId(_ n: UInt8) -> [UInt8] { [UInt8](repeating: n, count: 16) }

    // MARK: - Single goal

    func testCancelActiveGoalMovesItToCanceling() async throws {
        let rig = try await Rig.make()
        let id = Self.goalId(1)
        try await rig.send(id, behavior: .runUntilCanceled)

        let response = try Self.decode(await rig.cancel(id))
        XCTAssertEqual(response.returnCode, Self.errorNone)
        XCTAssertEqual(response.canceling.map(\.uuid), [id])
        XCTAssertEqual(rig.handler.cancelCalls(), [id])
        try await rig.waitForStatus(id, .canceled)
        await rig.shutdown()
    }

    func testCancelTerminalGoalIsGoalTerminated() async throws {
        let rig = try await Rig.make()
        for (n, behavior, status) in [
            (UInt8(1), Behavior.succeed, ActionGoalStatus.succeeded),
            (UInt8(2), Behavior.fail, ActionGoalStatus.aborted),
        ] {
            let id = Self.goalId(n)
            try await rig.send(id, behavior: behavior)
            try await rig.waitForStatus(id, status)
            let response = try Self.decode(await rig.cancel(id))
            XCTAssertEqual(response.returnCode, Self.errorGoalTerminated, "\(status)")
            XCTAssertTrue(response.canceling.isEmpty)
        }

        // A canceled goal is terminal too.
        let id = Self.goalId(3)
        try await rig.send(id, behavior: .runUntilCanceled)
        _ = try await rig.cancel(id)
        try await rig.waitForStatus(id, .canceled)
        let response = try Self.decode(await rig.cancel(id))
        XCTAssertEqual(response.returnCode, Self.errorGoalTerminated)
        XCTAssertTrue(response.canceling.isEmpty)

        // handleCancel ran once, for the goal that was still running.
        XCTAssertEqual(rig.handler.cancelCalls(), [id])
        // A terminal goal keeps its terminal status.
        XCTAssertEqual(rig.status(Self.goalId(1)), .succeeded)
        XCTAssertEqual(rig.status(Self.goalId(2)), .aborted)
        await rig.shutdown()
    }

    func testCancelUnknownGoalIsUnknownGoalId() async throws {
        let rig = try await Rig.make()
        try await rig.send(Self.goalId(1), behavior: .runUntilCanceled)

        let response = try Self.decode(await rig.cancel(Self.goalId(9)))
        XCTAssertEqual(response.returnCode, Self.errorUnknownGoalId)
        XCTAssertTrue(response.canceling.isEmpty)
        XCTAssertTrue(rig.handler.cancelCalls().isEmpty)
        await rig.shutdown()
    }

    func testRejectedCancelLeavesTheGoalRunning() async throws {
        let rig = try await Rig.make(cancelResponse: .reject)
        let id = Self.goalId(1)
        try await rig.send(id, behavior: .runUntilCanceled)

        let response = try Self.decode(await rig.cancel(id))
        XCTAssertEqual(response.returnCode, Self.errorRejected)
        XCTAssertTrue(response.canceling.isEmpty)
        XCTAssertNotEqual(rig.status(id), .canceling)
        await rig.shutdown()
    }

    // MARK: - Cancel all

    func testCancelAllSkipsTerminalGoals() async throws {
        let rig = try await Rig.make()
        let done = Self.goalId(1)
        let failed = Self.goalId(2)
        let running = [Self.goalId(3), Self.goalId(4)]
        try await rig.send(done, behavior: .succeed)
        try await rig.send(failed, behavior: .fail)
        for id in running { try await rig.send(id, behavior: .runUntilCanceled) }
        try await rig.waitForStatus(done, .succeeded)
        try await rig.waitForStatus(failed, .aborted)

        let response = try Self.decode(await rig.cancel(nil))
        XCTAssertEqual(response.returnCode, Self.errorNone)
        XCTAssertEqual(Set(response.canceling.map(\.uuid)), Set(running))
        XCTAssertEqual(Set(rig.handler.cancelCalls()), Set(running))
        for id in running { try await rig.waitForStatus(id, .canceled) }
        XCTAssertEqual(rig.status(done), .succeeded)
        XCTAssertEqual(rig.status(failed), .aborted)
        await rig.shutdown()
    }

    func testCancelAllWithOnlyTerminalGoalsIsNoneAndEmpty() async throws {
        let rig = try await Rig.make()
        let done = Self.goalId(1)
        try await rig.send(done, behavior: .succeed)
        try await rig.waitForStatus(done, .succeeded)

        let response = try Self.decode(await rig.cancel(nil))
        XCTAssertEqual(response.returnCode, Self.errorNone)
        XCTAssertTrue(response.canceling.isEmpty)
        XCTAssertTrue(rig.handler.cancelCalls().isEmpty)
        XCTAssertEqual(rig.status(done), .succeeded)

        // Same with no goals at all.
        let empty = try await Rig.make()
        let emptyResponse = try Self.decode(await empty.cancel(nil))
        XCTAssertEqual(emptyResponse.returnCode, Self.errorNone)
        XCTAssertTrue(emptyResponse.canceling.isEmpty)
        await rig.shutdown()
        await empty.shutdown()
    }

    func testCancelAllSkipsGoalsAlreadyCanceling() async throws {
        let rig = try await Rig.make()
        let id = Self.goalId(1)
        try await rig.send(id, behavior: .ignoreCancelUntilReleased)

        let first = try Self.decode(await rig.cancel(nil))
        XCTAssertEqual(first.canceling.map(\.uuid), [id])
        XCTAssertEqual(rig.status(id), .canceling)

        let second = try Self.decode(await rig.cancel(nil))
        XCTAssertEqual(second.returnCode, Self.errorNone)
        XCTAssertTrue(second.canceling.isEmpty)
        XCTAssertEqual(rig.handler.cancelCalls(), [id])
        rig.handler.release()
        await rig.shutdown()
    }

    // MARK: - By stamp

    func testCancelByStampPicksOnlyActiveGoalsAcceptedAtOrBefore() async throws {
        let rig = try await Rig.make()
        let doneEarly = Self.goalId(1)
        let early = Self.goalId(2)
        let boundary = Self.goalId(3)
        let late = Self.goalId(4)
        try await rig.send(doneEarly, behavior: .succeed)
        try await rig.waitForStatus(doneEarly, .succeeded)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await rig.send(early, behavior: .runUntilCanceled)
        try await Task.sleep(nanoseconds: 20_000_000)
        let stamp = try await rig.send(boundary, behavior: .runUntilCanceled)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await rig.send(late, behavior: .runUntilCanceled)

        let response = try Self.decode(await rig.cancel(nil, stamp: stamp))
        XCTAssertEqual(response.returnCode, Self.errorNone)
        XCTAssertEqual(Set(response.canceling.map(\.uuid)), [early, boundary])
        XCTAssertEqual(Set(rig.handler.cancelCalls()), [early, boundary])
        XCTAssertEqual(rig.status(doneEarly), .succeeded)
        try await rig.waitForStatus(early, .canceled)
        try await rig.waitForStatus(boundary, .canceled)
        XCTAssertNotEqual(rig.status(late), .canceling)

        // Only terminal goals are left at or before an early stamp.
        let none = try Self.decode(await rig.cancel(nil, stamp: stamp))
        XCTAssertEqual(none.returnCode, Self.errorNone)
        XCTAssertTrue(none.canceling.isEmpty)
        await rig.shutdown()
    }

    func testCancelByIdAndStampAlsoSkipsTerminalGoals() async throws {
        let rig = try await Rig.make()
        let done = Self.goalId(1)
        let running = Self.goalId(2)
        try await rig.send(done, behavior: .succeed)
        try await rig.waitForStatus(done, .succeeded)
        let stamp = try await rig.send(running, behavior: .runUntilCanceled)

        // Id of a terminal goal plus a stamp: the sweep still only finds the running goal.
        let response = try Self.decode(await rig.cancel(done, stamp: stamp))
        XCTAssertEqual(response.returnCode, Self.errorNone)
        XCTAssertEqual(response.canceling.map(\.uuid), [running])
        XCTAssertEqual(rig.status(done), .succeeded)
        await rig.shutdown()
    }
}

// MARK: - Rig

private enum Behavior {
    case succeed
    case fail
    case runUntilCanceled
    /// Keeps running after a cancel request until `release()`.
    case ignoreCancelUntilReleased
}

private struct _Failure: Error {}

private final class _Handler: ActionServerHandler, @unchecked Sendable {
    typealias Action = FibonacciAction

    private let lock = NSLock()
    private var behaviors: [UInt8: Behavior] = [:]
    private var calls: [[UInt8]] = []
    private var released = false
    let cancelResponse: CancelResponse

    init(cancelResponse: CancelResponse) { self.cancelResponse = cancelResponse }

    func setBehavior(_ behavior: Behavior, key: UInt8) {
        lock.withLock { behaviors[key] = behavior }
    }

    private func behavior(for key: UInt8) -> Behavior {
        lock.withLock { behaviors[key] ?? .succeed }
    }

    private func recordCancel(_ id: [UInt8]) {
        lock.withLock { calls.append(id) }
    }

    func cancelCalls() -> [[UInt8]] {
        lock.withLock { calls }
    }

    func release() {
        lock.withLock { released = true }
    }

    private var isReleased: Bool {
        lock.withLock { released }
    }

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }

    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
        let id = withUnsafeBytes(of: handle.goalId.uuid) { Array($0) }
        recordCancel(id)
        return cancelResponse
    }

    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
        switch behavior(for: handle.goalId.uuid.0) {
        case .succeed:
            return FibonacciAction.Result(sequence: [0, 1])
        case .fail:
            throw _Failure()
        case .runUntilCanceled:
            while true {
                if await handle.isCancelRequested { throw CancellationError() }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        case .ignoreCancelUntilReleased:
            // `try?` so the task cancellation that follows a cancel request does not end the goal.
            while !isReleased { try? await Task.sleep(nanoseconds: 5_000_000) }
            return FibonacciAction.Result(sequence: [0, 1])
        }
    }
}

private struct Rig {
    let ctx: ROS2Context
    let handlers: TransportActionServerHandlers
    let server: MockActionServer
    let handler: _Handler

    static func make(cancelResponse: CancelResponse = .accept) async throws -> Rig {
        let mock = MockTransportSession()
        let server = MockActionServer()
        let captured = Box<TransportActionServerHandlers?>(nil)
        mock.actionServerFactory = { _, _, _, _, handlers in
            captured.value = handlers
            return server
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let handler = _Handler(cancelResponse: cancelResponse)
        _ = try await node.createActionServer(FibonacciAction.self, name: "/fibonacci", handler: handler)
        return Rig(ctx: ctx, handlers: try XCTUnwrap(captured.value), server: server, handler: handler)
    }

    func shutdown() async {
        handler.release()
        await ctx.shutdown()
    }

    /// Sends a goal; the handler keys its behavior by the first byte of the goal id.
    @discardableResult
    func send(_ id: [UInt8], behavior: Behavior) async throws -> (sec: Int32, nanosec: UInt32) {
        handler.setBehavior(behavior, key: id[0])
        let encoder = CDREncoder(isLegacySchema: false)
        encoder.writeEncapsulationHeader()
        try FibonacciAction.Goal(order: 1).encode(to: encoder)
        let (accepted, sec, nanosec) = try await handlers.onSendGoal(id, encoder.getData())
        XCTAssertTrue(accepted)
        return (sec, nanosec)
    }

    /// Sends a CancelGoal request; `nil` id is the zero id.
    func cancel(_ id: [UInt8]?, stamp: (sec: Int32, nanosec: UInt32)? = nil) async throws -> Data {
        var request = Data([0x00, 0x01, 0x00, 0x00])
        request.append(contentsOf: id ?? [UInt8](repeating: 0, count: 16))
        var sec = (stamp?.sec ?? 0).littleEndian
        var nanosec = (stamp?.nanosec ?? 0).littleEndian
        withUnsafeBytes(of: &sec) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: &nanosec) { request.append(contentsOf: $0) }
        return try await handlers.onCancelGoal(request)
    }

    /// The latest published status of a goal.
    func status(_ id: [UInt8]) -> ActionGoalStatus? {
        let entry = server.publishedStatuses.last?.first { $0.uuid == id }
        return entry.flatMap { ActionGoalStatus(rawValue: $0.status) }
    }

    func waitForStatus(_ id: [UInt8], _ expected: ActionGoalStatus) async throws {
        await waitUntil("goal \(id[0]) never reached \(expected); last \(String(describing: status(id)))") {
            status(id) == expected
        }
    }
}

extension ActionCancelGoalTests {
    fileprivate struct Decoded {
        var returnCode: Int8
        var canceling: [(uuid: [UInt8], sec: Int32, nanosec: UInt32)]
    }

    /// Decodes a CancelGoal response: header, return code, then the goals_canceling sequence.
    fileprivate static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        XCTAssertGreaterThanOrEqual(bytes.count, 12)
        let count = Int(
            UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }))
        XCTAssertEqual(bytes.count, 12 + 24 * count)
        var entries: [(uuid: [UInt8], sec: Int32, nanosec: UInt32)] = []
        for i in 0..<count {
            let o = 12 + 24 * i
            entries.append((Array(bytes[o..<(o + 16)]), 0, 0))
        }
        return Decoded(returnCode: Int8(bitPattern: bytes[4]), canceling: entries)
    }
}
