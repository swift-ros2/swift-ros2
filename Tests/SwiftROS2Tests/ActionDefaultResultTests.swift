// ActionDefaultResultTests.swift
// GetResult responses for goals that end without a result.
//
// rcl's action server answers a canceled, aborted or unknown goal with the
// status and a default-constructed result, and rmw clients deserialize every
// response as the typed `<Action>_GetResult_Response`. The goldens were
// captured with `rclpy.serialization.serialize_message` on ROS 2 Jazzy from
// `<Action>.Impl.GetResultService.Response()` with only `status` set.

import Foundation
import SwiftROS2ExampleInterfaces
import SwiftROS2TestFixtures
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

final class ActionDefaultResultTests: XCTestCase {
    private static let goalId: [UInt8] = Array(1...16)

    // MARK: - Goldens (rclpy, ROS 2 Jazzy)

    /// Fibonacci GetResult response with a default result (an empty
    /// sequence), status byte at offset 4.
    private static func fibonacciDefaultResponse(status: Int8) -> Data {
        var frame = bytes("000100000000000000000000")
        frame[4] = UInt8(bitPattern: status)
        return frame
    }

    /// LookupTransform GetResult response with a default result: empty frame
    /// ids, zero translation, rotation (0, 0, 0, 1) and error 0 "". Status
    /// byte at offset 4.
    private static func lookupTransformDefaultResponse(status: Int8) -> Data {
        var frame = bytes(
            "0001000000000000000000000000000001000000000000000100000000000000000000000000000000000000"
                + "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
                + "0000f03f000000000100000000")
        frame[4] = UInt8(bitPattern: status)
        return frame
    }

    /// Offset of `rotation.w` (float64 1.0) in `lookupTransformDefaultResponse`.
    private static let lookupTransformRotationW = 84..<92

    // MARK: - Zero-valued results

    func testZeroValuedFibonacciResultIsTheDefault() throws {
        XCTAssertEqual(try ZeroValuedResult.make(FibonacciAction.Result.self), FibonacciAction.Result())
    }

    func testZeroValuedLookupTransformResultDiffersOnlyInIDLDefaults() throws {
        var expected = LookupTransformAction.Result()
        XCTAssertEqual(expected.transform.transform.rotation.w, 1.0)  // geometry_msgs/Quaternion IDL default
        expected.transform.transform.rotation.w = 0
        XCTAssertEqual(try ZeroValuedResult.make(LookupTransformAction.Result.self), expected)
    }

    func testZeroValuedResultGrowsPastTheFirstBuffer() throws {
        let result = try ZeroValuedResult.make(_LargeFixedResult.self)
        XCTAssertEqual(result.values.count, _LargeFixedResult.count)
        XCTAssertTrue(result.values.allSatisfy { $0 == 0 })
    }

    // MARK: - Server: canceled / aborted / unknown

    func testCanceledFibonacciGoalSendsTheDefaultResult() async throws {
        let ack = try await serve(FibonacciAction.self, handler: _ThrowingFibonacciHandler(error: CancellationError()))
        XCTAssertEqual(ack.status, ActionGoalStatus.canceled.rawValue)
        XCTAssertEqual(Array(frame(ack)), Array(Self.fibonacciDefaultResponse(status: 5)))
    }

    func testAbortedFibonacciGoalSendsTheDefaultResult() async throws {
        let ack = try await serve(FibonacciAction.self, handler: _ThrowingFibonacciHandler(error: _Failure()))
        XCTAssertEqual(ack.status, ActionGoalStatus.aborted.rawValue)
        XCTAssertEqual(Array(frame(ack)), Array(Self.fibonacciDefaultResponse(status: 6)))
    }

    func testCancelRequestSendsTheDefaultResult() async throws {
        let (ctx, handlers) = try await makeServer(FibonacciAction.self, handler: _WaitForCancelHandler())
        let (accepted, _, _) = try await handlers.onSendGoal(
            Self.goalId, try Self.encode(FibonacciAction.Goal(order: 5)))
        XCTAssertTrue(accepted)

        // CancelGoal request: header, the goal UUID, a zero stamp.
        var cancelRequest = Data([0x00, 0x01, 0x00, 0x00])
        cancelRequest.append(contentsOf: Self.goalId)
        cancelRequest.append(contentsOf: [UInt8](repeating: 0, count: 8))
        let cancelResponse = try await handlers.onCancelGoal(cancelRequest)
        XCTAssertEqual(cancelResponse[4], 0)  // ERROR_NONE

        let ack = try await handlers.onGetResult(Self.goalId)
        XCTAssertEqual(ack.status, ActionGoalStatus.canceled.rawValue)
        XCTAssertEqual(Array(frame(ack)), Array(Self.fibonacciDefaultResponse(status: 5)))
        await ctx.shutdown()
    }

    func testDefaultResultOverrideSendsIDLDefaults() async throws {
        for (error, status) in [(CancellationError() as any Error, Int8(5)), (_Failure(), Int8(6))] {
            let ack = try await serve(
                LookupTransformAction.self, handler: _ThrowingLookupTransformHandler(error: error, idlDefaults: true))
            XCTAssertEqual(ack.status, status)
            XCTAssertEqual(Array(frame(ack)), Array(Self.lookupTransformDefaultResponse(status: status)))
        }
    }

    func testZeroValuedLookupTransformResultMatchesTheGoldenExceptRotationW() async throws {
        let ack = try await serve(
            LookupTransformAction.self, handler: _ThrowingLookupTransformHandler(error: CancellationError()))
        var golden = Self.lookupTransformDefaultResponse(status: 5)
        golden.replaceSubrange(Self.lookupTransformRotationW, with: [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(Array(frame(ack)), Array(golden))
    }

    func testUnknownGoalSendsStatusUnknownWithTheDefaultResult() async throws {
        let (ctx, handlers) = try await makeServer(
            LookupTransformAction.self, handler: _ThrowingLookupTransformHandler(error: _Failure(), idlDefaults: true))
        let ack = try await handlers.onGetResult(Self.goalId)
        XCTAssertEqual(ack.status, ActionGoalStatus.unknown.rawValue)
        XCTAssertEqual(Array(frame(ack)), Array(Self.lookupTransformDefaultResponse(status: 0)))
        await ctx.shutdown()
    }

    func testThrowingDefaultResultFallsBackToTheMinimalFrame() async throws {
        let ack = try await serve(
            LookupTransformAction.self,
            handler: _ThrowingLookupTransformHandler(error: _Failure(), defaultResultFails: true))
        XCTAssertEqual(ack.status, ActionGoalStatus.aborted.rawValue)
        XCTAssertTrue(ack.resultCDR.isEmpty)
        XCTAssertEqual(Array(frame(ack)), [0x00, 0x01, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00])
    }

    // MARK: - Client

    func testClientReadsTheRclpyCanceledAndAbortedResponses() async throws {
        let canceled = try await clientResult(Self.lookupTransformDefaultResponse(status: 5))
        guard case .canceled = canceled else { return XCTFail("expected canceled, got \(canceled)") }
        let aborted = try await clientResult(Self.lookupTransformDefaultResponse(status: 6))
        guard case .aborted = aborted else { return XCTFail("expected aborted, got \(aborted)") }
    }

    func testClientReadsTheMinimalFrameOfAnOlderServer() async throws {
        // swift-ros2 servers before the default result sent the status alone.
        let canceled = try await clientResult(Data([0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00]))
        guard case .canceled = canceled else { return XCTFail("expected canceled, got \(canceled)") }
        let aborted = try await clientResult(Data([0x00, 0x01, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00]))
        guard case .aborted = aborted else { return XCTFail("expected aborted, got \(aborted)") }
    }

    // MARK: - Helpers

    private func makeServer<H: ActionServerHandler>(
        _ action: H.Action.Type, handler: H
    ) async throws -> (ROS2Context, TransportActionServerHandlers) {
        let mock = MockTransportSession()
        let captured = MockActionServer.Box()
        mock.actionServerFactory = { _, _, _, _, handlers in
            captured.handlers = handlers
            return MockActionServer()
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        _ = try await node.createActionServer(action, name: "/action", handler: handler)
        return (ctx, try XCTUnwrap(captured.handlers))
    }

    /// Sends one goal (a default goal) and returns its GetResult answer.
    private func serve<H: ActionServerHandler>(_ action: H.Action.Type, handler: H) async throws -> GetResultAck
    where H.Action.Goal: _DefaultGoal {
        let (ctx, handlers) = try await makeServer(action, handler: handler)
        let (accepted, _, _) = try await handlers.onSendGoal(Self.goalId, try Self.encode(H.Action.Goal.makeDefault()))
        XCTAssertTrue(accepted)
        let ack = try await handlers.onGetResult(Self.goalId)
        await ctx.shutdown()
        return ack
    }

    /// The wire frame every transport sends for `ack`.
    private func frame(_ ack: GetResultAck) -> Data {
        ActionFrameDecoder.encodeGetResultResponse(status: ack.status, resultCDR: ack.resultCDR)
    }

    private func clientResult(_ wire: Data) async throws -> ActionResult<LookupTransformAction.Result> {
        let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(from: wire)
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(getResultStatus: status, getResultCDR: resultCDR)
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let client = try await node.createActionClient(LookupTransformAction.self, name: "/action")
        let handle = try await client.sendGoal(LookupTransformAction.Goal())
        let result = try await handle.result(timeout: .seconds(2))
        await ctx.shutdown()
        return result
    }

    private static func encode(_ value: some CDRCodable) throws -> Data {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try value.encode(to: encoder)
        return encoder.getData()
    }

    private static func bytes(_ hex: String) -> Data {
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}

// MARK: - Fixtures

private struct _Failure: Error {}

private protocol _DefaultGoal: CDRCodable { static func makeDefault() -> Self }
extension FibonacciAction.Goal: _DefaultGoal { static func makeDefault() -> Self { Self() } }
extension LookupTransformAction.Goal: _DefaultGoal { static func makeDefault() -> Self { Self() } }

/// A result whose zero value needs more than the first 256-byte buffer.
private struct _LargeFixedResult: CDRCodable, Sendable {
    static let count = 1000
    var values: [Double]

    func encode(to encoder: CDREncoder) throws {
        for v in values { encoder.writeFloat64(v) }
    }

    init(from decoder: CDRDecoder) throws {
        values = try (0..<Self.count).map { _ in try decoder.readFloat64() }
    }
}

private actor _ThrowingFibonacciHandler: ActionServerHandler {
    typealias Action = FibonacciAction
    let error: any Error

    init(error: any Error) { self.error = error }

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }
    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .accept }
    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
        throw error
    }
}

private actor _WaitForCancelHandler: ActionServerHandler {
    typealias Action = FibonacciAction

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse { .accept }
    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse { .accept }
    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws -> FibonacciAction.Result {
        while true {
            if await handle.isCancelRequested { throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor _ThrowingLookupTransformHandler: ActionServerHandler {
    typealias Action = LookupTransformAction
    let error: any Error
    let idlDefaults: Bool
    let defaultResultFails: Bool

    init(error: any Error, idlDefaults: Bool = false, defaultResultFails: Bool = false) {
        self.error = error
        self.idlDefaults = idlDefaults
        self.defaultResultFails = defaultResultFails
    }

    func handleGoal(_ goal: LookupTransformAction.Goal) async -> GoalResponse { .accept }
    func handleCancel(_ handle: ActionGoalHandle<LookupTransformAction>) async -> CancelResponse { .accept }
    func execute(_ handle: ActionGoalHandle<LookupTransformAction>) async throws -> LookupTransformAction.Result {
        throw error
    }

    func defaultResult() async throws -> LookupTransformAction.Result {
        if defaultResultFails { throw _Failure() }
        if idlDefaults { return Action.Result() }
        return try ZeroValuedResult.make(Action.Result.self)
    }
}
