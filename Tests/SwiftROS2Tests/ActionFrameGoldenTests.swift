// ActionFrameGoldenTests.swift
// Golden bytes for every action wrapper frame, as real ROS 2 serializes them.
//
// Captured with `rclpy.serialization.serialize_message` on ROS 2 Jazzy for
// tf2_msgs/action/LookupTransform, example_interfaces/action/Fibonacci,
// action_msgs/msg/GoalStatusArray and action_msgs/srv/CancelGoal. XCDR v1
// aligns every field from the end of the encapsulation header, so a payload
// nested after the goal UUID or the result status keeps the frame's alignment
// origin, not its own. LookupTransform's result (float64 fields after a
// header and two strings, behind a 1-byte status) is the case that broke.

import Foundation
import SwiftROS2ExampleInterfaces
import SwiftROS2TestFixtures
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

final class ActionFrameGoldenTests: XCTestCase {
    private static let goalId: [UInt8] = Array(1...16)

    // MARK: - Goldens (rclpy, ROS 2 Jazzy)

    /// LookupTransform SendGoal request: target "map", source "base_link",
    /// source_time 1.000000002, timeout 3.000000004, target_time 5.000000006,
    /// fixed "odom", advanced. Bytes 42..<44 are uninitialized padding.
    private static let lookupTransformSendGoalRequest = bytes(
        "000100000102030405060708090a0b0c0d0e0f10040000006d6170000a000000626173655f6c696e6b006e64"
            + "010000000200000003000000040000000500000006000000050000006f646f6d0001")
    /// LookupTransform SendGoal response: accepted, stamp 1700000000.123456789.
    private static let lookupTransformSendGoalResponse = bytes("000100000100000000f1536515cd5b07")
    private static let getResultRequest = bytes("000100000102030405060708090a0b0c0d0e0f10")
    /// LookupTransform GetResult response, status SUCCEEDED (4): stamp 10.000000020,
    /// frame "world", child "base_link", translation (1.5, -2.25, 3.125),
    /// rotation (0.1, 0.2, 0.3, 0.9), error 1 "warn".
    private static let lookupTransformGetResultResponse = bytes(
        "00010000040000000a0000001400000006000000776f726c640000000a000000626173655f6c696e6b000000"
            + "000000000000f83f00000000000002c000000000000009409a9999999999b93f9a9999999999c93f"
            + "333333333333d33fcdccccccccccec3f01000000050000007761726e00")
    /// LookupTransform GetResult response, status CANCELED (5), default result.
    /// Some padding bytes are left uninitialized by the serializer.
    private static let lookupTransformCanceledResponse = bytes(
        "0001000005000000000000000000000001000000000000000100000000000000660000000000000000000000"
            + "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
            + "0000f03f000000000100000000")
    /// LookupTransform FeedbackMessage (empty feedback: one dummy uint8). The
    /// serializer pads the end of the buffer to a 4-byte multiple.
    private static let lookupTransformFeedback = bytes(
        "000100000102030405060708090a0b0c0d0e0f1000000000")
    /// Fibonacci SendGoal request, order 10.
    private static let fibonacciSendGoalRequest = bytes(
        "000100000102030405060708090a0b0c0d0e0f100a000000")
    /// Fibonacci GetResult response, status 4, sequence [0, 1, 1, 2, 3].
    private static let fibonacciGetResultResponse = bytes(
        "0001000004000000050000000000000001000000010000000200000003000000")
    /// Fibonacci FeedbackMessage, partial sequence [0, 1, 1].
    private static let fibonacciFeedback = bytes(
        "000100000102030405060708090a0b0c0d0e0f1003000000000000000100000001000000")
    /// GoalStatusArray with three goals: uuid `16n ..< 16n + 16`,
    /// stamp (100 + n).(200 + n), status 2 + n. Bytes 49..<52 and 77..<80 are
    /// padding the serializer left uninitialized.
    private static let statusArray = bytes(
        "0001000003000000000102030405060708090a0b0c0d0e0f64000000c800000002101112131415161718191a"
            + "1b1c1d1e1f1a173c65000000c900000003202122232425262728292a2b2c2d2e2f00000066000000ca000000"
            + "04")
    /// CancelGoal response, return code 0, the first two goals of `statusArray`.
    /// Bytes 5..<8 are uninitialized padding.
    private static let cancelGoalResponse = bytes(
        "00010000007f000002000000000102030405060708090a0b0c0d0e0f64000000c8000000101112131415161718"
            + "191a1b1c1d1e1f65000000c9000000")

    // MARK: - Expected values

    private static var lookupTransformGoal: LookupTransformAction.Goal {
        var goal = LookupTransformAction.Goal(
            targetFrame: "map", sourceFrame: "base_link", fixedFrame: "odom", advanced: true)
        goal.sourceTime.sec = 1
        goal.sourceTime.nanosec = 2
        goal.timeout.sec = 3
        goal.timeout.nanosec = 4
        goal.targetTime.sec = 5
        goal.targetTime.nanosec = 6
        return goal
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

    private static let statusEntries: [ActionFrameDecoder.StatusEntry] = [
        (uuid: Array(0x00...0x0F), stampSec: 100, stampNanosec: 200, status: 2),
        (uuid: Array(0x10...0x1F), stampSec: 101, stampNanosec: 201, status: 3),
        (uuid: Array(0x20...0x2F), stampSec: 102, stampNanosec: 202, status: 4),
    ]

    // MARK: - SendGoal

    func testLookupTransformSendGoalRequestMatchesGolden() throws {
        let goalCDR = try Self.encode(Self.lookupTransformGoal)
        let frame = ActionFrameDecoder.encodeSendGoalRequest(goalId: Self.goalId, goalCDR: goalCDR)
        var golden = Self.lookupTransformSendGoalRequest
        for i in 42..<44 { golden[i] = 0 }
        XCTAssertEqual(Array(frame), Array(golden))

        let (goalId, decodedCDR) = try ActionFrameDecoder.decodeSendGoalRequest(
            from: Self.lookupTransformSendGoalRequest)
        XCTAssertEqual(goalId, Self.goalId)
        XCTAssertEqual(try LookupTransformAction.Goal(from: CDRDecoder(data: decodedCDR)), Self.lookupTransformGoal)
    }

    func testFibonacciSendGoalRequestMatchesGolden() throws {
        let goalCDR = try Self.encode(FibonacciAction.Goal(order: 10))
        let frame = ActionFrameDecoder.encodeSendGoalRequest(goalId: Self.goalId, goalCDR: goalCDR)
        XCTAssertEqual(Array(frame), Array(Self.fibonacciSendGoalRequest))

        let (goalId, decodedCDR) = try ActionFrameDecoder.decodeSendGoalRequest(
            from: Self.fibonacciSendGoalRequest)
        XCTAssertEqual(goalId, Self.goalId)
        XCTAssertEqual(try FibonacciAction.Goal(from: CDRDecoder(data: decodedCDR)).order, 10)
    }

    func testSendGoalResponseMatchesGolden() throws {
        let frame = ActionFrameDecoder.encodeSendGoalResponse(
            accepted: true, stampSec: 1_700_000_000, stampNanosec: 123_456_789)
        XCTAssertEqual(Array(frame), Array(Self.lookupTransformSendGoalResponse))

        let decoded = try ActionFrameDecoder.decodeSendGoalResponse(
            from: Self.lookupTransformSendGoalResponse)
        XCTAssertTrue(decoded.accepted)
        XCTAssertEqual(decoded.stampSec, 1_700_000_000)
        XCTAssertEqual(decoded.stampNanosec, 123_456_789)
    }

    // MARK: - GetResult

    func testGetResultRequestMatchesGolden() throws {
        let frame = ActionFrameDecoder.encodeGetResultRequest(goalId: Self.goalId)
        XCTAssertEqual(Array(frame), Array(Self.getResultRequest))
        XCTAssertEqual(try ActionFrameDecoder.decodeGetResultRequest(from: Self.getResultRequest), Self.goalId)
    }

    func testLookupTransformGetResultResponseMatchesGolden() throws {
        let resultCDR = try Self.encodeResultResponse(status: 4, Self.lookupTransformResult)
        let frame = ActionFrameDecoder.encodeGetResultResponse(status: 4, resultCDR: resultCDR)
        XCTAssertEqual(Array(frame), Array(Self.lookupTransformGetResultResponse))
        // The same bytes as the rosidl wrapper encoded in one pass.
        let wrapper = LookupTransform_GetResult_Response(status: 4, result: Self.lookupTransformResult)
        XCTAssertEqual(Array(frame), Array(try Self.encode(wrapper)))
    }

    func testLookupTransformGetResultResponseDecodesGolden() throws {
        let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(
            from: Self.lookupTransformGetResultResponse)
        XCTAssertEqual(status, 4)
        let result = try Self.decodeResultResponse(LookupTransformAction.Result.self, resultCDR)
        XCTAssertEqual(result.transform.transform.translation.x, 1.5)
        XCTAssertEqual(result.transform.transform.translation.y, -2.25)
        XCTAssertEqual(result, Self.lookupTransformResult)
    }

    func testCanceledGetResultResponseDecodesGolden() throws {
        let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(
            from: Self.lookupTransformCanceledResponse)
        XCTAssertEqual(status, 5)
        XCTAssertEqual(
            try Self.decodeResultResponse(LookupTransformAction.Result.self, resultCDR),
            LookupTransformAction.Result())
    }

    func testFibonacciGetResultResponseMatchesGolden() throws {
        let result = FibonacciAction.Result(sequence: [0, 1, 1, 2, 3])
        let resultCDR = try Self.encodeResultResponse(status: 4, result)
        let frame = ActionFrameDecoder.encodeGetResultResponse(status: 4, resultCDR: resultCDR)
        XCTAssertEqual(Array(frame), Array(Self.fibonacciGetResultResponse))

        let (status, decodedCDR) = try ActionFrameDecoder.decodeGetResultResponse(
            from: Self.fibonacciGetResultResponse)
        XCTAssertEqual(status, 4)
        XCTAssertEqual(try Self.decodeResultResponse(FibonacciAction.Result.self, decodedCDR), result)
    }

    func testGetResultResponseWithoutResultIsTheMinimalFrame() {
        XCTAssertEqual(
            Array(ActionFrameDecoder.encodeGetResultResponse(status: 6, resultCDR: Data())),
            [0x00, 0x01, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00])
    }

    // MARK: - FeedbackMessage

    func testLookupTransformFeedbackMatchesGolden() throws {
        let feedbackCDR = try Self.encode(LookupTransformAction.Feedback())
        let frame = ActionFrameDecoder.encodeFeedbackMessage(goalId: Self.goalId, feedbackCDR: feedbackCDR)
        // The golden carries 3 bytes of end-of-buffer padding after the dummy byte.
        XCTAssertEqual(Array(frame), Array(Self.lookupTransformFeedback.prefix(frame.count)))
        XCTAssertEqual(Self.lookupTransformFeedback.count - frame.count, 3)

        let (goalId, decodedCDR) = try ActionFrameDecoder.decodeFeedbackMessage(
            from: Self.lookupTransformFeedback)
        XCTAssertEqual(goalId, Self.goalId)
        XCTAssertNoThrow(try LookupTransformAction.Feedback(from: CDRDecoder(data: decodedCDR)))
    }

    func testFibonacciFeedbackMatchesGolden() throws {
        let feedbackCDR = try Self.encode(FibonacciAction.Feedback(sequence: [0, 1, 1]))
        let frame = ActionFrameDecoder.encodeFeedbackMessage(goalId: Self.goalId, feedbackCDR: feedbackCDR)
        XCTAssertEqual(Array(frame), Array(Self.fibonacciFeedback))

        let (goalId, decodedCDR) = try ActionFrameDecoder.decodeFeedbackMessage(from: Self.fibonacciFeedback)
        XCTAssertEqual(goalId, Self.goalId)
        XCTAssertEqual(try FibonacciAction.Feedback(from: CDRDecoder(data: decodedCDR)).sequence, [0, 1, 1])
    }

    // MARK: - GoalStatusArray

    func testStatusArrayMatchesGolden() throws {
        var golden = Self.statusArray
        for i in [49, 50, 51, 77, 78, 79] { golden[i] = 0 }
        XCTAssertEqual(Array(ActionFrameDecoder.encodeStatusArray(entries: Self.statusEntries)), Array(golden))

        let decoded = try ActionFrameDecoder.decodeStatusArray(from: Self.statusArray)
        XCTAssertEqual(decoded.count, 3)
        for (got, want) in zip(decoded, Self.statusEntries) {
            XCTAssertEqual(got.uuid, want.uuid)
            XCTAssertEqual(got.stampSec, want.stampSec)
            XCTAssertEqual(got.stampNanosec, want.stampNanosec)
            XCTAssertEqual(got.status, want.status)
        }
    }

    func testStatusArrayRejectsACountThePayloadCannotHold() {
        var frame = Self.statusArray
        frame[4] = 4  // claims four goals, carries three
        XCTAssertThrowsError(try ActionFrameDecoder.decodeStatusArray(from: frame))
    }

    // MARK: - CancelGoal response

    func testCancelGoalResponseMatchesGolden() throws {
        var golden = Self.cancelGoalResponse
        for i in 5..<8 { golden[i] = 0 }
        let entries = Self.statusEntries.prefix(2).map {
            (uuid: $0.uuid, stampSec: $0.stampSec, stampNanosec: $0.stampNanosec)
        }
        XCTAssertEqual(
            Array(ROS2ActionServer<_LookupTransformHandler>.encodeCancelGoalResponse(returnCode: 0, entries: entries)),
            Array(golden))

        let ack = try RclTransportActionClient.decodeCancelGoalResponse(from: Self.cancelGoalResponse)
        XCTAssertEqual(ack.returnCode, 0)
        XCTAssertEqual(ack.goalsCanceling.map(\.uuid), entries.map(\.uuid))
        XCTAssertEqual(ack.goalsCanceling.map(\.stampSec), [100, 101])
        XCTAssertEqual(ack.goalsCanceling.map(\.stampNanosec), [200, 201])
    }

    // MARK: - Umbrella round trip

    func testActionServerEncodesTheGoldenResultResponse() async throws {
        let mock = MockTransportSession()
        let captured = Box<TransportActionServerHandlers?>(nil)
        mock.actionServerFactory = { _, _, _, _, handlers in
            captured.value = handlers
            return MockActionServer()
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        _ = try await node.createActionServer(
            LookupTransformAction.self, name: "/lookup_transform",
            handler: _LookupTransformHandler(result: Self.lookupTransformResult))

        let (accepted, _, _) = try await captured.value!.onSendGoal(
            Self.goalId, try Self.encode(Self.lookupTransformGoal))
        XCTAssertTrue(accepted)
        var ack: GetResultAck?
        for _ in 0..<40 {
            if let r = try? await captured.value!.onGetResult(Self.goalId),
                r.status == ActionGoalStatus.succeeded.rawValue
            {
                ack = r
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let result = try XCTUnwrap(ack)
        let frame = ActionFrameDecoder.encodeGetResultResponse(status: result.status, resultCDR: result.resultCDR)
        XCTAssertEqual(Array(frame), Array(Self.lookupTransformGetResultResponse))
        await ctx.shutdown()
    }

    func testActionClientDecodesTheGoldenResultResponse() async throws {
        let (status, resultCDR) = try ActionFrameDecoder.decodeGetResultResponse(
            from: Self.lookupTransformGetResultResponse)
        let mock = MockTransportSession()
        mock.actionClientFactory = { _, _, _, _ in
            MockActionClient.makeAccepting(getResultStatus: status, getResultCDR: resultCDR)
        }
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: .jazzy, session: mock)
        let node = try await ctx.createNode(name: "t", options: ROS2NodeOptions(startParameterServices: false))
        let client = try await node.createActionClient(LookupTransformAction.self, name: "/lookup_transform")
        let handle = try await client.sendGoal(Self.lookupTransformGoal)
        guard case .succeeded(let result) = try await handle.result(timeout: .seconds(2)) else {
            return XCTFail("expected a succeeded result")
        }
        XCTAssertEqual(result, Self.lookupTransformResult)
        await ctx.shutdown()
    }

    // MARK: - Helpers

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

    /// A payload as the umbrella encodes goals and feedback: header, then the fields.
    private static func encode(_ value: some CDRCodable) throws -> Data {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try value.encode(to: encoder)
        return encoder.getData()
    }

    /// A result as the umbrella encodes it: the whole GetResult response in one pass.
    private static func encodeResultResponse(status: Int8, _ result: some CDRCodable) throws -> Data {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        encoder.writeInt8(status)
        try result.encode(to: encoder)
        return encoder.getData()
    }

    private static func decodeResultResponse<R: CDRCodable>(_ type: R.Type, _ resultCDR: Data) throws -> R {
        let decoder = try CDRDecoder(data: resultCDR)
        _ = try decoder.readInt8()
        return try R(from: decoder)
    }
}

actor _LookupTransformHandler: ActionServerHandler {
    typealias Action = LookupTransformAction
    private let result: LookupTransformAction.Result

    init(result: LookupTransformAction.Result = LookupTransformAction.Result()) {
        self.result = result
    }

    func handleGoal(_ goal: LookupTransformAction.Goal) async -> GoalResponse { .accept }

    func handleCancel(_ handle: ActionGoalHandle<LookupTransformAction>) async -> CancelResponse { .accept }

    func execute(_ handle: ActionGoalHandle<LookupTransformAction>) async throws -> LookupTransformAction.Result {
        result
    }
}
