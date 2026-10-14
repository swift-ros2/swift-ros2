// ActionFrameDecoderTests.swift
// Round-trip tests for the per-frame CDR helpers shared between the DDS and Zenoh
// action transports.

import Foundation
import XCTest

@testable import SwiftROS2Transport

final class ActionFrameDecoderTests: XCTestCase {
    private let cdrHeader = Data([0x00, 0x01, 0x00, 0x00])  // XCDR v1 little-endian
    private let goalId16 = [UInt8](repeating: 0xAB, count: 16)

    func testEncodeDecodeSendGoalRequestRoundTrip() throws {
        // User-encoded Goal payload as the umbrella hands it over (with header).
        let goalCDR = cdrHeader + Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = ActionFrameDecoder.encodeSendGoalRequest(goalId: goalId16, goalCDR: goalCDR)
        let (parsedId, parsedGoal) = try ActionFrameDecoder.decodeSendGoalRequest(from: frame)
        XCTAssertEqual(parsedId, goalId16)
        XCTAssertEqual(parsedGoal, goalCDR)
    }

    func testSendGoalRequestCarriesASingleEncapsulationHeader() throws {
        // Fibonacci goal { int32 order = 5 } as the umbrella encodes it (with header).
        let userGoal = Data([0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
        let goalId = [UInt8](repeating: 0xAB, count: 16)
        let frame = ActionFrameDecoder.encodeSendGoalRequest(goalId: goalId, goalCDR: userGoal)
        // [header | uuid[16] | order] — a real rmw server reads order = 5, not 256.
        XCTAssertEqual(Array(frame), [0x00, 0x01, 0x00, 0x00] + goalId + [0x05, 0x00, 0x00, 0x00])
    }

    func testDecodeRestoresHeaderEvenWhenBodyLooksLikeOne() throws {
        // A bare body whose first int32 is 256 (00 01 00 00) must survive.
        let goalId = [UInt8](repeating: 0x01, count: 16)
        let wire = Data([0x00, 0x01, 0x00, 0x00] + goalId + [0x00, 0x01, 0x00, 0x00])
        let (_, goalCDR) = try ActionFrameDecoder.decodeSendGoalRequest(from: wire)
        XCTAssertEqual(Array(goalCDR), [0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
    }

    func testFeedbackAndResultFramesCarryASingleHeader() throws {
        let body = Data([0x00, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        let goalId = [UInt8](repeating: 0x02, count: 16)
        XCTAssertEqual(
            Array(ActionFrameDecoder.encodeFeedbackMessage(goalId: goalId, feedbackCDR: body)),
            [0x00, 0x01, 0x00, 0x00] + goalId + [0x02, 0x00, 0x00, 0x00])
        // The result arrives as the whole response, [header | status slot | result];
        // the frame keeps it byte for byte apart from the stamped status.
        let response = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(
            Array(ActionFrameDecoder.encodeGetResultResponse(status: 4, resultCDR: response)),
            [0x00, 0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
    }

    func testResultIsNotRealignedToAFixedOffset() throws {
        // [status | bool] — rosidl puts a 1-byte first field right after the
        // status, with no padding. A fixed 3-byte pad would shift it.
        let response = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(
            Array(ActionFrameDecoder.encodeGetResultResponse(status: 4, resultCDR: response)),
            [0x00, 0x01, 0x00, 0x00, 0x04, 0x01])
        let (status, decoded) = try ActionFrameDecoder.decodeGetResultResponse(
            from: Data([0x00, 0x01, 0x00, 0x00, 0x04, 0x01]))
        XCTAssertEqual(status, 4)
        XCTAssertEqual(Array(decoded), [0x00, 0x01, 0x00, 0x00, 0x04, 0x01])
    }

    func testDecodedFeedbackAndResultCarryExactlyOneHeader() throws {
        // Frames as a real rmw peer emits them: bare bodies at the splice offset.
        let goalId = [UInt8](repeating: 0x03, count: 16)
        let fbWire = Data([0x00, 0x01, 0x00, 0x00] + goalId + [0x07, 0x00, 0x00, 0x00])
        let (_, fb) = try ActionFrameDecoder.decodeFeedbackMessage(from: fbWire)
        XCTAssertEqual(Array(fb), [0x00, 0x01, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00])

        // The result comes back as the whole response so it keeps its alignment origin.
        let resultWire = Data([0x00, 0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00])
        let (status, result) = try ActionFrameDecoder.decodeGetResultResponse(from: resultWire)
        XCTAssertEqual(status, 4)
        XCTAssertEqual(result, resultWire)
    }

    func testStripInnerEncapsulationHeader() {
        XCTAssertEqual(
            Array(ActionFrameDecoder.stripInnerEncapsulationHeader(cdrHeader + Data([0x05]))), [0x05])
        // Bare / short payloads pass through untouched.
        XCTAssertEqual(Array(ActionFrameDecoder.stripInnerEncapsulationHeader(Data([0x05]))), [0x05])
        XCTAssertEqual(ActionFrameDecoder.stripInnerEncapsulationHeader(Data()), Data())
    }

    func testDecodeSendGoalRequestTooShortThrows() {
        let tooShort = Data([0x00, 0x01, 0x00, 0x00, 0x00])  // header + 1 byte
        XCTAssertThrowsError(try ActionFrameDecoder.decodeSendGoalRequest(from: tooShort))
    }

    func testEncodeDecodeGetResultRequestRoundTrip() throws {
        let frame = ActionFrameDecoder.encodeGetResultRequest(goalId: goalId16)
        let parsedId = try ActionFrameDecoder.decodeGetResultRequest(from: frame)
        XCTAssertEqual(parsedId, goalId16)
    }

    func testEncodeSendGoalResponse() {
        let frame = ActionFrameDecoder.encodeSendGoalResponse(
            accepted: true, stampSec: 7, stampNanosec: 11
        )
        // [header (4) | accepted (1) | pad (3) | sec (4) | nanosec (4)]
        XCTAssertEqual(frame.count, 4 + 1 + 3 + 4 + 4)
        XCTAssertEqual(frame[0..<4], cdrHeader)
        XCTAssertEqual(frame[4], 1)
        // Sec / nanosec start at offset 8 due to alignment.
        let sec = frame.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: Int32.self).littleEndian
        }
        let nsec = frame.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
        XCTAssertEqual(sec, 7)
        XCTAssertEqual(nsec, 11)
    }

    func testEncodeGetResultResponse() {
        let resultCDR = cdrHeader + Data([0x00, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44])
        let frame = ActionFrameDecoder.encodeGetResultResponse(
            status: 4, resultCDR: resultCDR
        )
        // [header (4) | status (1) | the result's own padding and fields ...]
        XCTAssertEqual(frame[0..<4], cdrHeader)
        XCTAssertEqual(frame[4], 4)
        XCTAssertEqual(frame.dropFirst(5), resultCDR.dropFirst(5))
    }

    func testEncodeDecodeFeedbackMessageRoundTrip() throws {
        let userCDR = cdrHeader + Data([0x77, 0x88])  // umbrella-encoded (with header)
        let frame = ActionFrameDecoder.encodeFeedbackMessage(
            goalId: goalId16, feedbackCDR: userCDR
        )
        let (parsedId, parsedFeedback) = try ActionFrameDecoder.decodeFeedbackMessage(
            from: frame
        )
        XCTAssertEqual(parsedId, goalId16)
        XCTAssertEqual(parsedFeedback, userCDR)
    }

    func testEncodeDecodeStatusArrayRoundTrip() throws {
        let entries: [ActionFrameDecoder.StatusEntry] = [
            (uuid: goalId16, stampSec: 1, stampNanosec: 2, status: 1),
            (uuid: Array(repeating: 0xCD, count: 16), stampSec: 3, stampNanosec: 4, status: 4),
        ]
        let frame = ActionFrameDecoder.encodeStatusArray(entries: entries)
        let parsed = try ActionFrameDecoder.decodeStatusArray(from: frame)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].uuid, entries[0].uuid)
        XCTAssertEqual(parsed[0].status, 1)
        XCTAssertEqual(parsed[1].uuid, entries[1].uuid)
        XCTAssertEqual(parsed[1].status, 4)
    }

    func testDecodeStatusArrayEmptyRoundTrip() throws {
        let frame = ActionFrameDecoder.encodeStatusArray(entries: [])
        let parsed = try ActionFrameDecoder.decodeStatusArray(from: frame)
        XCTAssertTrue(parsed.isEmpty)
    }
}
