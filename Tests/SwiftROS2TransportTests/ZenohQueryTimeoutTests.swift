// ZenohQueryTimeoutTests.swift
// The millisecond timeout of a zenoh query, shared by service and action clients.

import XCTest

@testable import SwiftROS2Transport

final class ZenohQueryTimeoutTests: XCTestCase {
    func testDurationsBecomeMilliseconds() {
        XCTAssertEqual(Duration.seconds(5).zenohQueryTimeoutMs, 5_000)
        XCTAssertEqual(Duration.milliseconds(250).zenohQueryTimeoutMs, 250)
        // Below a millisecond rounds down.
        XCTAssertEqual(Duration.microseconds(1_999).zenohQueryTimeoutMs, 1)
        XCTAssertEqual(Duration.zero.zenohQueryTimeoutMs, 0)
    }

    func testOutOfRangeDurationsAreClamped() {
        XCTAssertEqual(Duration.seconds(-3).zenohQueryTimeoutMs, 0)
        XCTAssertEqual(Duration.seconds(Int64(UInt32.max)).zenohQueryTimeoutMs, UInt32.max)
        XCTAssertEqual(Duration.seconds(Int64.max).zenohQueryTimeoutMs, UInt32.max)
    }
}
