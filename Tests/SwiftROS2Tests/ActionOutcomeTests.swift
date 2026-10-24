// ActionOutcomeTests.swift
// `ActionGoalHandle.outcome(timeout:)` reads the result of every terminal status.
//
// rcl action servers answer the GetResult request of a canceled or aborted goal with the full
// result, and some of them put the reason for the failure in it (MoveIt's `move_group` sets
// `error_code`). `outcome(timeout:)` decodes it for every terminal status; `result(timeout:)`
// keeps returning `.canceled` / `.aborted(reason: nil)` without it.

import Foundation
import SwiftROS2ExampleInterfaces
import SwiftROS2TestFixtures
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

final class ActionOutcomeTests: XCTestCase {
    // MARK: - Frames

    /// LookupTransform GetResult response captured with rclpy on ROS 2 Jazzy (the
    /// `ActionFrameGoldenTests` golden) with its status byte, at offset 4, set to `status`. The
    /// status is a lone int8 before the result's alignment padding, so every status has the
    /// same result bytes. Result: stamp 10.000000020, frame "world", child "base_link",
    /// translation (1.5, -2.25, 3.125), rotation (0.1, 0.2, 0.3, 0.9), error 1 "warn".
    private static func lookupTransformResponse(status: Int8) -> Data {
        var frame = bytes(
            "00010000040000000a0000001400000006000000776f726c640000000a000000626173655f6c696e6b000000"
                + "000000000000f83f00000000000002c000000000000009409a9999999999b93f9a9999999999c93f"
                + "333333333333d33fcdccccccccccec3f01000000050000007761726e00")
        frame[4] = UInt8(bitPattern: status)
        return frame
    }

    private static var lookupTransformResult: LookupTransformAction.Result {
        var result = LookupTransformAction.Result()
        result.transform.header.stamp.sec = 10
        result.transform.header.stamp.nanosec = 20
        result.transform.header.frameId = "world"
        result.transform.childFrameId = "base_link"
        result.transform.transform.translation.x = 1.5
        result.transform.transform.translation.y = -2.25
        result.transform.transform.translation.z = 3.125
        result.transform.transform.rotation.x = 0.1
        result.transform.transform.rotation.y = 0.2
        result.transform.transform.rotation.z = 0.3
        result.transform.transform.rotation.w = 0.9
        result.error.error = 1
        result.error.errorString = "warn"
        return result
    }

    /// The status-only reply of a swift-ros2 server before 3.0: header, status, padding.
    private static func statusOnlyResponse(status: Int8) -> Data {
        Data([0x00, 0x01, 0x00, 0x00, UInt8(bitPattern: status), 0x00, 0x00, 0x00])
    }

    // MARK: - Aborted and canceled goals carry their result

    func testAbortedOutcomeCarriesTheDecodedResult() async throws {
        let outcome = try await outcome(ofWire: Self.lookupTransformResponse(status: 6))
        XCTAssertEqual(outcome.status, .aborted)
        XCTAssertEqual(outcome.result, Self.lookupTransformResult)
        XCTAssertEqual(outcome.result?.error.error, 1)
        XCTAssertEqual(outcome.result?.error.errorString, "warn")
        guard case .aborted(reason: nil) = outcome.actionResult else {
            return XCTFail("expected aborted, got \(outcome.actionResult)")
        }
    }

    func testCanceledOutcomeCarriesTheDecodedResult() async throws {
        let outcome = try await outcome(ofWire: Self.lookupTransformResponse(status: 5))
        XCTAssertEqual(outcome.status, .canceled)
        XCTAssertEqual(outcome.result, Self.lookupTransformResult)
        guard case .canceled = outcome.actionResult else {
            return XCTFail("expected canceled, got \(outcome.actionResult)")
        }
    }

    func testSucceededOutcomeCarriesTheDecodedResult() async throws {
        let outcome = try await outcome(ofWire: Self.lookupTransformResponse(status: 4))
        XCTAssertEqual(outcome.status, .succeeded)
        XCTAssertEqual(outcome.result, Self.lookupTransformResult)
        guard case .succeeded(let result) = outcome.actionResult else {
            return XCTFail("expected succeeded, got \(outcome.actionResult)")
        }
        XCTAssertEqual(result, Self.lookupTransformResult)
    }

    func testOutcomeOfAFibonacciGoalAbortedWithAPartialSequence() async throws {
        let handle = try await fibonacciHandle(status: 6, resultCDR: Self.fibonacciResponse(status: 6, [0, 1, 1]))
        let outcome = try await handle.outcome(timeout: .seconds(2))
        XCTAssertEqual(
            outcome, ActionOutcome(unsuccessful: .aborted, result: FibonacciAction.Result(sequence: [0, 1, 1])))
    }

    // MARK: - A canceled or aborted reply without a decodable result

    func testStatusOnlyReplyGivesTheStatusWithoutAResult() async throws {
        for status: Int8 in [5, 6] {
            let outcome = try await outcome(ofWire: Self.statusOnlyResponse(status: status))
            XCTAssertEqual(outcome.status.rawValue, status)
            XCTAssertNil(outcome.result, "status \(status)")
        }
    }

    func testEmptyReplyGivesTheStatusWithoutAResult() async throws {
        for status: Int8 in [5, 6] {
            let handle = try await lookupTransformHandle(status: status, resultCDR: Data())
            let outcome = try await handle.outcome(timeout: .seconds(2))
            XCTAssertEqual(outcome.status.rawValue, status)
            XCTAssertNil(outcome.result, "status \(status)")
            // `result()` is unaffected by the missing result.
            let result = try await handle.result(timeout: .seconds(2))
            switch (status, result) {
            case (5, .canceled), (6, .aborted(reason: nil)): break
            default: XCTFail("status \(status): got \(result)")
            }
        }
    }

    func testTruncatedResultGivesTheStatusWithoutAResult() async throws {
        let truncated = Self.lookupTransformResponse(status: 6).prefix(40)
        let outcome = try await outcome(ofWire: Data(truncated))
        XCTAssertEqual(outcome.status, .aborted)
        XCTAssertNil(outcome.result)
    }

    // MARK: - Errors match result(timeout:)

    func testSucceededReplyWithAnUndecodableResultThrows() async throws {
        let handle = try await lookupTransformHandle(status: 4, resultCDR: Self.statusOnlyResponse(status: 4))
        await assertThrows(try await handle.outcome(timeout: .seconds(2))) {
            guard case .responseDecodingFailed = $0 else { return XCTFail("got \($0)") }
        }
        await assertThrows(try await handle.result(timeout: .seconds(2))) {
            guard case .responseDecodingFailed = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testNonTerminalStatusThrows() async throws {
        for status: Int8 in [0, 1, 2, 3, 7] {
            let handle = try await lookupTransformHandle(
                status: status, resultCDR: Self.statusOnlyResponse(status: status))
            await assertThrows(try await handle.outcome(timeout: .seconds(2))) {
                guard case .mapping = $0 else { return XCTFail("status \(status): got \($0)") }
            }
            await assertThrows(try await handle.result(timeout: .seconds(2))) {
                guard case .mapping = $0 else { return XCTFail("status \(status): got \($0)") }
            }
        }
    }

    func testTimeoutThrowsResultTimedOut() async throws {
        let handle = try await lookupTransformHandle(
            status: 6, resultCDR: Data(), getResultError: TransportError.requestTimeout(.seconds(1)))
        await assertThrows(try await handle.outcome(timeout: .seconds(1))) {
            guard case .resultTimedOut = $0 else { return XCTFail("got \($0)") }
        }
        await assertThrows(try await handle.result(timeout: .seconds(1))) {
            guard case .resultTimedOut = $0 else { return XCTFail("got \($0)") }
        }
    }

    func testTransportFailureThrowsMapping() async throws {
        let handle = try await lookupTransformHandle(
            status: 6, resultCDR: Data(), getResultError: TransportError.notConnected)
        await assertThrows(try await handle.outcome(timeout: .seconds(1))) {
            guard case .mapping = $0 else { return XCTFail("got \($0)") }
        }
    }

    // MARK: - result(timeout:) is unchanged

    func testResultIgnoresTheResultOfCanceledAndAbortedGoals() async throws {
        let canceled = try await lookupTransformHandle(status: 5, wire: Self.lookupTransformResponse(status: 5))
        guard case .canceled = try await canceled.result(timeout: .seconds(2)) else {
            return XCTFail("expected canceled")
        }
        let aborted = try await lookupTransformHandle(status: 6, wire: Self.lookupTransformResponse(status: 6))
        guard case .aborted(reason: nil) = try await aborted.result(timeout: .seconds(2)) else {
            return XCTFail("expected aborted without a reason")
        }
        let succeeded = try await lookupTransformHandle(status: 4, wire: Self.lookupTransformResponse(status: 4))
        guard case .succeeded(let result) = try await succeeded.result(timeout: .seconds(2)) else {
            return XCTFail("expected succeeded")
        }
        XCTAssertEqual(result, Self.lookupTransformResult)
    }

    // MARK: - Per-distribution layouts

    /// `distro_test_msgs/Plan` gains `smoothness` in Lyrical: the result of an aborted goal is
    /// read with the layout of the context's distribution, after the status and its padding.
    func testAbortedOutcomeDecodesTheLayoutOfTheContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            // [header | status | 7 padding bytes | Plan], Plan's float64 aligned to 8.
            let wire = Data(DistroFixture.header + [6, 0, 0, 0, 0, 0, 0, 0] + DistroFixture.planBody(distro))
            let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(from: wire)
            let mock = MockTransportSession()
            mock.actionClientFactory = { _, _, _, _ in
                MockActionClient.makeAccepting(getResultStatus: status, getResultCDR: resultCDR)
            }
            let ctx = try await ROS2Context(
                transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: distro, session: mock)
            let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
            let client = try await node.createActionClient(_PlanResultAction.self, name: "/plan")
            let handle = try await client.sendGoal(Plan())
            let outcome = try await handle.outcome(timeout: .seconds(2))
            XCTAssertEqual(outcome.status, .aborted, "\(distro)")
            XCTAssertEqual(outcome.result, DistroFixture.decodedPlan(distro), "\(distro)")
            await ctx.shutdown()
        }
    }

    // MARK: - Helpers

    private func outcome(ofWire wire: Data) async throws -> ActionOutcome<LookupTransformAction.Result> {
        let (status, _) = try ActionFrameDecoder.decodeGetResultResponse(from: wire)
        let handle = try await lookupTransformHandle(status: status, wire: wire)
        return try await handle.outcome(timeout: .seconds(2))
    }

    private func lookupTransformHandle(status: Int8, wire: Data) async throws -> ActionGoalHandle<LookupTransformAction>
    {
        let (_, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(from: wire)
        return try await lookupTransformHandle(status: status, resultCDR: resultCDR)
    }

    /// A client handle whose GetResult answers `status` and `resultCDR` (the whole response),
    /// or throws `getResultError`. The context stays open until the test ends.
    private func lookupTransformHandle(
        status: Int8, resultCDR: Data, getResultError: (any Error)? = nil
    ) async throws -> ActionGoalHandle<LookupTransformAction> {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(
                getResultStatus: status, getResultCDR: resultCDR, getResultError: getResultError)
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        addTeardownBlock { await ctx.shutdown() }
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let client = try await node.createActionClient(LookupTransformAction.self, name: "/lookup_transform")
        return try await client.sendGoal(LookupTransformAction.Goal())
    }

    private func fibonacciHandle(status: Int8, resultCDR: Data) async throws -> ActionGoalHandle<FibonacciAction> {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(getResultStatus: status, getResultCDR: resultCDR)
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        addTeardownBlock { await ctx.shutdown() }
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let client = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        return try await client.sendGoal(FibonacciAction.Goal(order: 5))
    }

    /// A Fibonacci GetResult response: [header | status | result].
    private static func fibonacciResponse(status: Int8, _ sequence: [Int32]) -> Data {
        let encoder = CDREncoder(distro: .jazzy)
        encoder.writeEncapsulationHeader()
        encoder.writeInt8(status)
        try! FibonacciAction.Result(sequence: sequence).encode(to: encoder)
        return encoder.getData()
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line,
        _ check: (ActionError) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected an ActionError", file: file, line: line)
        } catch let error as ActionError {
            check(error)
        } catch {
            XCTFail("expected an ActionError, got \(error)", file: file, line: line)
        }
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

/// An action whose result is `distro_test_msgs/Plan`, whose layout differs between Jazzy and
/// Lyrical. Only the client's decode path uses it, so its hashes are not real.
private enum _PlanResultAction: ROS2Action {
    typealias Goal = Plan
    typealias Result = Plan
    typealias Feedback = Plan

    static let typeInfo = ROS2ActionTypeInfo(
        actionName: "distro_test_msgs/action/PlanResult",
        goalTypeHash: nil,
        resultTypeHash: nil,
        feedbackTypeHash: nil,
        sendGoalRequestTypeHash: nil,
        sendGoalResponseTypeHash: nil,
        getResultRequestTypeHash: nil,
        getResultResponseTypeHash: nil,
        feedbackMessageTypeHash: nil
    )
}
