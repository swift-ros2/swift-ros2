import SwiftROS2CDR
import SwiftROS2ExampleInterfaces
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

final class SubscriptionDecodeFailureTests: XCTestCase {
    /// Collects the log lines and drives the clock of a `DecodeFailureReporter`.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var _nowNs: UInt64 = 1_000_000_000

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _lines
        }

        func advance(seconds: Double) {
            lock.lock()
            _nowNs += UInt64(seconds * 1_000_000_000)
            lock.unlock()
        }

        func reporter(interval: TimeInterval = 10) -> DecodeFailureReporter {
            DecodeFailureReporter(
                topic: "/ns/chatter",
                typeName: "example_interfaces/msg/String",
                interval: interval,
                now: { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    return _nowNs
                },
                emit: { [self] line in
                    lock.lock()
                    _lines.append(line)
                    lock.unlock()
                })
        }
    }

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "boom" }
    }

    // MARK: - Reporter

    func testFirstFailureIsLoggedWithTopicTypeAndError() {
        let harness = Harness()
        let reporter = harness.reporter()
        reporter.record(Boom())

        XCTAssertEqual(reporter.count, 1)
        XCTAssertEqual(harness.lines.count, 1)
        let line = harness.lines[0]
        XCTAssertTrue(line.contains("/ns/chatter"), line)
        XCTAssertTrue(line.contains("example_interfaces/msg/String"), line)
        XCTAssertTrue(line.contains("boom"), line)
    }

    func testFailuresInsideTheIntervalAreCountedButNotLogged() {
        let harness = Harness()
        let reporter = harness.reporter()
        reporter.record(Boom())
        harness.advance(seconds: 3)
        reporter.record(Boom())
        harness.advance(seconds: 3)
        reporter.record(Boom())

        XCTAssertEqual(reporter.count, 3)
        XCTAssertEqual(harness.lines.count, 1)
    }

    func testNextLogAfterTheIntervalCarriesTheSuppressedCount() {
        let harness = Harness()
        let reporter = harness.reporter()
        reporter.record(Boom())
        reporter.record(Boom())
        reporter.record(Boom())
        harness.advance(seconds: 10)
        reporter.record(Boom())

        XCTAssertEqual(reporter.count, 4)
        XCTAssertEqual(harness.lines.count, 2)
        XCTAssertTrue(harness.lines[1].contains("3 failures since the last report"), harness.lines[1])
        XCTAssertTrue(harness.lines[1].contains("4 in total"), harness.lines[1])
    }

    func testLogsAgainEachIntervalWhileFailuresContinue() {
        let harness = Harness()
        let reporter = harness.reporter(interval: 5)
        for _ in 0..<4 {
            reporter.record(Boom())
            harness.advance(seconds: 5)
        }
        XCTAssertEqual(harness.lines.count, 4)
        XCTAssertEqual(reporter.count, 4)
    }

    // MARK: - Subscription

    private func makeNode() async throws -> (ROS2Node, MockTransportSession) {
        let session = MockTransportSession()
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/mock:7447"), session: session)
        return (try await ctx.createNode(name: "n", namespace: "/ns"), session)
    }

    func testMalformedPayloadIsCountedAndNotDelivered() async throws {
        let (node, session) = try await makeNode()
        let sub = try await node.createSubscription(StringMsg.self, topic: "chatter")
        XCTAssertEqual(sub.decodeFailureCount, 0)

        // Too short for the 4-byte CDR encapsulation header.
        session.subscribers[0].handler(Data([0x00, 0x01]), 0)
        // A valid header followed by a string whose length prefix overruns the buffer.
        session.subscribers[0].handler(Data([0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00]), 0)

        XCTAssertEqual(sub.decodeFailureCount, 2)

        // A good message still arrives afterwards and is not counted as a failure.
        let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")
        try pub.publish(StringMsg(data: "ok"))
        var iterator = sub.messages.makeAsyncIterator()
        let message = await iterator.next()
        XCTAssertEqual(message?.data, "ok")
        XCTAssertEqual(sub.decodeFailureCount, 2)
        sub.cancel()
    }

    func testSubscriptionRecordsFailuresIntoItsReporter() {
        let harness = Harness()
        let sub = ROS2Subscription<StringMsg>(topic: "/ns/chatter", decodeFailures: harness.reporter())
        sub.receiveDecodeFailure(Boom())
        XCTAssertEqual(sub.decodeFailureCount, 1)
        XCTAssertEqual(harness.lines.count, 1)
    }
}
