// ActionClientTests.swift
// Mock-session-driven tests for ROS2ActionClient.

import Foundation
import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

final class ActionClientTests: XCTestCase {
    func testSendGoalAcceptedReturnsHandle() async throws {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in MockActionClient.makeAccepting() }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        let handle = try await cli.sendGoal(FibonacciAction.Goal(order: 5))
        XCTAssertEqual(handle.acceptedAt.sec, 1)
        XCTAssertEqual(handle.acceptedAt.nanosec, 2)
        await ctx.shutdown()
    }

    func testSendGoalRejectedThrows() async throws {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in MockActionClient.makeRejecting() }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        do {
            _ = try await cli.sendGoal(FibonacciAction.Goal(order: 5))
            XCTFail("expected goalRejected")
        } catch let e as ActionError {
            if case .goalRejected = e {
                await ctx.shutdown()
                return
            }
            XCTFail("got \(e)")
        }
        await ctx.shutdown()
    }

    func testFeedbackDecodesToTypedSequence() async throws {
        let fb1 = Self.encodeFeedback([1, 1, 2])
        let fb2 = Self.encodeFeedback([1, 1, 2, 3])
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(feedbackCDRs: [fb1, fb2])
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        let handle = try await cli.sendGoal(FibonacciAction.Goal(order: 5))
        var seen: [[Int32]] = []
        for await fb in handle.feedback {
            seen.append(fb.sequence)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, [[1, 1, 2], [1, 1, 2, 3]])
        await ctx.shutdown()
    }

    func testResultSucceededDecodesPayload() async throws {
        let resultCDR = Self.encodeResult([0, 1, 1, 2, 3])
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(getResultStatus: 4, getResultCDR: resultCDR)
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        let handle = try await cli.sendGoal(FibonacciAction.Goal(order: 5))
        let r = try await handle.result(timeout: .seconds(2))
        if case .succeeded(let payload) = r {
            XCTAssertEqual(payload.sequence, [0, 1, 1, 2, 3])
        } else {
            XCTFail("expected succeeded, got \(r)")
        }
        await ctx.shutdown()
    }

    func testCancelGoalsBeforeStampReturnsEmptyForCleanRun() async throws {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in MockActionClient.makeAccepting() }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        let canceled = try await cli.cancelGoals(beforeStamp: BuiltinInterfacesTime(sec: 9, nanosec: 0))
        XCTAssertEqual(canceled, [])
        await ctx.shutdown()
    }

    func testHandleCancelReturnsWhenTheServerAccepts() async throws {
        let (ctx, handle) = try await Self.sendGoal(cancelReturnCode: 0)
        try await handle.cancel()
        await ctx.shutdown()
    }

    func testHandleCancelCarriesTheReasonOfEveryErrorCode() async throws {
        let expected: [(code: Int8, reason: CancelRejection)] = [
            (1, .rejected),  // ERROR_REJECTED
            (2, .unknownGoal),  // ERROR_UNKNOWN_GOAL_ID
            (3, .goalTerminated),  // ERROR_GOAL_TERMINATED
            (4, .unknown(4)),  // not defined by action_msgs/CancelGoal
            (-1, .unknown(-1)),
        ]
        for (code, reason) in expected {
            let (ctx, handle) = try await Self.sendGoal(cancelReturnCode: code)
            do {
                try await handle.cancel()
                XCTFail("expected cancelRejected for return code \(code)")
            } catch ActionError.cancelRejected(let got) {
                XCTAssertEqual(got, reason, "return code \(code)")
            } catch {
                XCTFail("return code \(code): got \(error)")
            }
            await ctx.shutdown()
        }
    }

    private static func sendGoal(
        cancelReturnCode: Int8
    ) async throws -> (ROS2Context, ActionGoalHandle<FibonacciAction>) {
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(cancelReturnCode: cancelReturnCode)
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0),
            distro: .jazzy,
            session: mock
        )
        let node = try await ctx.createNode(
            name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
        return (ctx, try await cli.sendGoal(FibonacciAction.Goal(order: 5)))
    }

    private static func encodeFeedback(_ seq: [Int32]) -> Data {
        let encoder = CDREncoder(isLegacySchema: false)
        encoder.writeEncapsulationHeader()
        try! FibonacciAction.Feedback(sequence: seq).encode(to: encoder)
        return encoder.getData()
    }

    private static func encodeResult(_ seq: [Int32]) -> Data {
        // The whole GetResult response: [header | status | result].
        let encoder = CDREncoder(isLegacySchema: false)
        encoder.writeEncapsulationHeader()
        encoder.writeInt8(4)
        try! FibonacciAction.Result(sequence: seq).encode(to: encoder)
        return encoder.getData()
    }
}
