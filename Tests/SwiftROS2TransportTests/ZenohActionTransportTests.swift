// ZenohActionTransportTests.swift
// End-to-end action flows over the Zenoh transport via MockZenohClient.

import Foundation
import XCTest

@testable import SwiftROS2Transport

final class ZenohActionTransportTests: XCTestCase {
    func testCloseWalksActionServersAndClients() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let server = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: TransportActionServerHandlers(
                onSendGoal: { _, _ in (true, 0, 0) },
                onCancelGoal: { _ in Data() },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
            )
        )
        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        XCTAssertTrue(server.isActive)
        XCTAssertTrue(client.isActive)

        try session.close()

        XCTAssertFalse(server.isActive)
        XCTAssertFalse(client.isActive)
    }

    func testServerSendGoalQueryRoutesToHandler() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let acceptedExpect = expectation(description: "onSendGoal called")
        let server = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: TransportActionServerHandlers(
                onSendGoal: { goalId, goalCDR in
                    XCTAssertEqual(goalId.count, 16)
                    // The bare wire body reaches the umbrella behind exactly one header.
                    XCTAssertEqual(Array(goalCDR), [0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
                    acceptedExpect.fulfill()
                    return (true, 7, 11)
                },
                onCancelGoal: { _ in Data() },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
            )
        )
        XCTAssertTrue(server.isActive)

        let goalId = [UInt8](repeating: 0xAA, count: 16)
        // Shaped as rmw_zenoh_cpp emits it: [header | uuid[16] | bare goal (order = 5)].
        let frame = Data([0x00, 0x01, 0x00, 0x00] + goalId + [0x05, 0x00, 0x00, 0x00])
        let key = (server as! ZenohTransportActionServerImpl).sendGoalKeyExpr
        let replies = try await mock.deliverQuery(keyExpr: key, payload: frame)

        await fulfillment(of: [acceptedExpect], timeout: 1)
        XCTAssertEqual(replies.count, 1)
        let resp = try ActionFrameDecoder.decodeSendGoalResponse(from: replies[0])
        XCTAssertTrue(resp.accepted)
        XCTAssertEqual(resp.stampSec, 7)
        XCTAssertEqual(resp.stampNanosec, 11)
    }

    func testServerPublishFeedbackEmitsToFeedbackKey() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let server = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: TransportActionServerHandlers(
                onSendGoal: { _, _ in (true, 0, 0) },
                onCancelGoal: { _ in Data() },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
            )
        )
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let impl = server as! ZenohTransportActionServerImpl
        // The umbrella hands over feedback with its own encapsulation header.
        try impl.publishFeedback(goalId: goalId, feedbackCDR: Data([0x00, 0x01, 0x00, 0x00, 0x77]))
        let writes = mock.putsByKey[impl.feedbackKeyExpr] ?? []
        XCTAssertEqual(writes.count, 1)
        // Exactly one header on the wire: [header | uuid[16] | bare feedback].
        XCTAssertEqual(Array(writes[0].payload), [0x00, 0x01, 0x00, 0x00] + goalId + [0x77])
        let (parsedId, fb) = try ActionFrameDecoder.decodeFeedbackMessage(from: writes[0].payload)
        XCTAssertEqual(parsedId, goalId)
        XCTAssertEqual(fb, Data([0x00, 0x01, 0x00, 0x00, 0x77]))
    }

    func testServerDeclaresLivelinessToken() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        _ = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: TransportActionServerHandlers(
                onSendGoal: { _, _ in (true, 0, 0) },
                onCancelGoal: { _ in Data() },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
            )
        )
        XCTAssertTrue(mock.declaredLivelinessTokens.contains { $0.contains("/SA/") })
    }

    func testClientSendGoalAcceptedYieldsFeedback() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )

        let goalId = [UInt8](repeating: 0xAA, count: 16)

        // Mock get(): when called on send_goal key, capture the request and
        // reply with accepted=true.
        let sentGoalFrame = Box<Data?>(nil)
        mock.getReplyHandler = { keyExpr, payload in
            guard keyExpr.contains("/_action/send_goal/") else { return nil }
            sentGoalFrame.value = payload
            return ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 99, stampNanosec: 0
            )
        }

        let ack = try await client.sendGoal(
            goalId: goalId,
            goalCDR: Data([0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00]),  // umbrella-encoded
            acceptanceTimeout: .seconds(2)
        )
        XCTAssertTrue(ack.accepted)
        XCTAssertEqual(ack.stampSec, 99)
        // No inner encapsulation header: a real rmw server reads order = 5, not 256.
        XCTAssertEqual(
            sentGoalFrame.value.map { Array($0) },
            [0x00, 0x01, 0x00, 0x00] + goalId + [0x05, 0x00, 0x00, 0x00])

        // Drive a feedback subscriber sample, shaped as a real rmw peer emits it.
        let feedbackKey = (client as! ZenohTransportActionClientImpl).feedbackKeyExpr
        let frame = Data([0x00, 0x01, 0x00, 0x00] + goalId + [0x77])
        mock.deliverSubscriberSample(keyExpr: feedbackKey, payload: frame, attachment: nil)

        var received: Data?
        for await fb in ack.feedback {
            received = fb
            break
        }
        XCTAssertEqual(received, Data([0x00, 0x01, 0x00, 0x00, 0x77]))
    }

    func testClientGetResultBlocksUntilReply() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        mock.getReplyHandler = { keyExpr, _ in
            guard keyExpr.contains("/_action/get_result/") else { return nil }
            return ActionFrameDecoder.encodeGetResultResponse(
                status: 4, resultCDR: Data([0x00, 0x01, 0x00, 0x00, 0x04, 0xAA, 0xBB]))
        }

        let ack = try await client.getResult(
            goalId: [UInt8](repeating: 0xAA, count: 16),
            timeout: .seconds(2)
        )
        XCTAssertEqual(ack.status, 4)
        // resultCDR is the whole response: [header | status | result].
        XCTAssertEqual(ack.resultCDR, Data([0x00, 0x01, 0x00, 0x00, 0x04, 0xAA, 0xBB]))
    }

    func testClientStatusFiltersByGoalId() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let myGoal = [UInt8](repeating: 0xAA, count: 16)
        let otherGoal = [UInt8](repeating: 0xBB, count: 16)
        mock.getReplyHandler = { keyExpr, _ in
            guard keyExpr.contains("/_action/send_goal/") else { return nil }
            return ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 0, stampNanosec: 0)
        }
        let ack = try await client.sendGoal(
            goalId: myGoal, goalCDR: Data(), acceptanceTimeout: .seconds(2))

        let statusKey = (client as! ZenohTransportActionClientImpl).statusKeyExpr
        let frame = ActionFrameDecoder.encodeStatusArray(entries: [
            (uuid: otherGoal, stampSec: 0, stampNanosec: 0, status: 2),
            (uuid: myGoal, stampSec: 0, stampNanosec: 0, status: 1),
            (uuid: myGoal, stampSec: 0, stampNanosec: 0, status: 4),
        ])
        mock.deliverSubscriberSample(keyExpr: statusKey, payload: frame, attachment: nil)

        var seen: [Int8] = []
        for await u in ack.status {
            seen.append(u.status)
        }
        XCTAssertEqual(seen, [1, 4])
    }

    func testWaitForActionServerThrowsOnTimeout() async throws {
        let mock = MockZenohClient()
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        // Default mock: no replies → probe always times out.
        do {
            try await client.waitForActionServer(timeout: .milliseconds(300))
            XCTFail("expected actionServerUnavailable")
        } catch let e as TransportError {
            if case .actionServerUnavailable = e { return }
            XCTFail("got \(e) instead of actionServerUnavailable")
        }
    }

    fileprivate func defaultHashes() -> ActionRoleTypeHashes {
        return ActionRoleTypeHashes(
            sendGoalRequest: nil, sendGoalResponse: nil,
            cancelGoalRequest: nil, cancelGoalResponse: nil,
            getResultRequest: nil, getResultResponse: nil,
            feedbackMessage: nil, statusArray: nil
        )
    }
}
