import SwiftROS2
import SwiftROS2ExampleInterfaces
import XCTest

final class FibonacciCDRTests: XCTestCase {

    func testGoalRoundTrip() throws {
        let original = FibonacciAction.Goal(order: 10)
        let enc = CDREncoder()
        enc.writeEncapsulationHeader()
        try original.encode(to: enc)
        let dec = try CDRDecoder(data: enc.getData())
        let decoded = try FibonacciAction.Goal(from: dec)
        XCTAssertEqual(decoded.order, 10)
    }

    func testResultRoundTrip() throws {
        let original = FibonacciAction.Result(sequence: [0, 1, 1, 2, 3, 5, 8])
        let enc = CDREncoder()
        enc.writeEncapsulationHeader()
        try original.encode(to: enc)
        let dec = try CDRDecoder(data: enc.getData())
        let decoded = try FibonacciAction.Result(from: dec)
        XCTAssertEqual(decoded.sequence, [0, 1, 1, 2, 3, 5, 8])
    }

    func testFeedbackRoundTrip() throws {
        let original = FibonacciAction.Feedback(sequence: [0, 1, 1])
        let enc = CDREncoder()
        enc.writeEncapsulationHeader()
        try original.encode(to: enc)
        let dec = try CDRDecoder(data: enc.getData())
        let decoded = try FibonacciAction.Feedback(from: dec)
        XCTAssertEqual(decoded.sequence, [0, 1, 1])
    }

    func testTypeInfoShape() {
        let info = FibonacciAction.typeInfo
        XCTAssertEqual(info.actionName, "example_interfaces/action/Fibonacci")
        XCTAssertNotNil(info.goalTypeHash)
        XCTAssertNotNil(info.resultTypeHash)
        XCTAssertNotNil(info.feedbackTypeHash)
        XCTAssertNotNil(info.sendGoalRequestTypeHash)
        XCTAssertNotNil(info.sendGoalResponseTypeHash)
        XCTAssertNotNil(info.getResultRequestTypeHash)
        XCTAssertNotNil(info.getResultResponseTypeHash)
        XCTAssertNotNil(info.feedbackMessageTypeHash)
    }

    func testEndToEndWrapperRoundTrip() throws {
        // Phase 6: per-action `Fibonacci_SendGoal_Request` round-trips through
        // CDR. The encapsulation header is written by the caller (Publisher /
        // Service / Action client analogue); test code mirrors that here.
        let goalId = UniqueIdentifierUUID(uuid: Array(repeating: 0xAB, count: 16))
        let original = Fibonacci_SendGoal_Request(
            goalId: goalId,
            goal: FibonacciAction.Goal(order: 5)
        )
        let enc = CDREncoder()
        enc.writeEncapsulationHeader()
        try original.encode(to: enc)
        let dec = try CDRDecoder(data: enc.getData())
        let decoded = try Fibonacci_SendGoal_Request(from: dec)
        XCTAssertEqual(decoded.goal.order, 5)
        XCTAssertEqual(decoded.goalId.uuid, original.goalId.uuid)
    }
}
