// DDSActionTransportTests.swift
// End-to-end action flows over the DDS transport via MockDDSClient.

import Foundation
import XCTest

@testable import SwiftROS2Transport

final class DDSActionTransportTests: XCTestCase {
    func testCloseWalksActionServersAndClients() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let handlers = TransportActionServerHandlers(
            onSendGoal: { _, _ in (true, 0, 0) },
            onCancelGoal: { _ in Data() },
            onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
        )

        let server = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: handlers
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

    func testServerOnSendGoalAcceptsAndPublishesStatus() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let acceptedExpect = expectation(description: "onSendGoal called")
        let handlers = TransportActionServerHandlers(
            onSendGoal: { goalId, goalCDR in
                XCTAssertEqual(goalId.count, 16)
                // The bare wire body reaches the umbrella behind exactly one header.
                XCTAssertEqual(Array(goalCDR), [0x00, 0x01, 0x00, 0x00, 0x11, 0x22])
                acceptedExpect.fulfill()
                return (true, 100, 200)
            },
            onCancelGoal: { _ in Data() },
            onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
        )

        let serverProto = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: handlers
        )
        let server = serverProto as! DDSTransportActionServerImpl

        // Drive a request through the mock send_goal request reader, shaped as
        // rmw_cyclonedds_cpp emits it: [header | guid (8) | seq (8) | uuid[16] | bare goal].
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let prefixed = Data(
            [0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0xCC, count: 8)
                + [0x01, 0, 0, 0, 0, 0, 0, 0] + goalId + [0x11, 0x22])
        mock.deliverRequestSample(topic: server.sendGoalRequestTopic, data: prefixed)

        await fulfillment(of: [acceptedExpect], timeout: 20)

        // Reply was written to the matching reply topic. The reply may land
        // slightly after the handler returns (Task.detached scheduling), so
        // poll briefly for it.
        try await waitForWrite(mock: mock, topic: server.sendGoalReplyTopic, timeout: 20)
        let writes = mock.writesByTopic[server.sendGoalReplyTopic] ?? []
        XCTAssertEqual(writes.count, 1)
        // The reply echoes the 16-byte request header verbatim.
        XCTAssertEqual(
            Array(writes[0].prefix(20)),
            [0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0xCC, count: 8) + [0x01, 0, 0, 0, 0, 0, 0, 0])
        let (_, decodedReply) = try SampleIdentityPrefix.decode(wirePayload: writes[0])
        let resp = try ActionFrameDecoder.decodeSendGoalResponse(from: decodedReply)
        XCTAssertTrue(resp.accepted)
        XCTAssertEqual(resp.stampSec, 100)
        XCTAssertEqual(resp.stampNanosec, 200)
    }

    func testServerCancelGoalRoutesToHandler() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let cancelExpect = expectation(description: "onCancelGoal called")
        // The cancel-response CDR must include its 4-byte encapsulation header
        // so `SampleIdentityPrefix.encode` can strip it before prefixing.
        let cancelResponseCDR = Data([0x00, 0x01, 0x00, 0x00, 0xCC, 0xDD])
        let handlers = TransportActionServerHandlers(
            onSendGoal: { _, _ in (false, 0, 0) },
            onCancelGoal: { req in
                XCTAssertFalse(req.isEmpty)
                cancelExpect.fulfill()
                return cancelResponseCDR
            },
            onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
        )

        let serverProto = try session.createActionServer(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default,
            handlers: handlers
        )
        let server = serverProto as! DDSTransportActionServerImpl

        let prefixed = SampleIdentityPrefix.encode(
            requestId: RMWRequestId(
                writerGuid: [UInt8](repeating: 0xCC, count: 8), sequenceNumber: 2),
            userCDR: Data([0x00, 0x01, 0x00, 0x00, 0x42])  // arbitrary cancel payload
        )
        mock.deliverRequestSample(topic: server.cancelGoalRequestTopic, data: prefixed)
        await fulfillment(of: [cancelExpect], timeout: 20)

        try await waitForWrite(mock: mock, topic: server.cancelGoalReplyTopic, timeout: 20)
        let writes = mock.writesByTopic[server.cancelGoalReplyTopic] ?? []
        XCTAssertEqual(writes.count, 1)
        let (_, decoded) = try SampleIdentityPrefix.decode(wirePayload: writes[0])
        XCTAssertEqual(decoded, cancelResponseCDR)
    }

    func testServerPublishFeedbackEmitsToFeedbackTopic() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let serverProto = try session.createActionServer(
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
        let server = serverProto as! DDSTransportActionServerImpl
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        // The umbrella hands over feedback with its own encapsulation header.
        try server.publishFeedback(goalId: goalId, feedbackCDR: Data([0x00, 0x01, 0x00, 0x00, 0x77]))

        let writes = mock.writesByTopic[server.feedbackTopic] ?? []
        XCTAssertEqual(writes.count, 1)
        // Exactly one header on the wire: [header | uuid[16] | bare feedback].
        XCTAssertEqual(Array(writes[0]), [0x00, 0x01, 0x00, 0x00] + goalId + [0x77])
        let (parsedId, parsedFB) = try ActionFrameDecoder.decodeFeedbackMessage(from: writes[0])
        XCTAssertEqual(parsedId, goalId)
        XCTAssertEqual(parsedFB, Data([0x00, 0x01, 0x00, 0x00, 0x77]))
    }

    func testServerPublishStatusArrayEmitsToStatusTopic() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let serverProto = try session.createActionServer(
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
        let server = serverProto as! DDSTransportActionServerImpl
        let goalId = [UInt8](repeating: 0xBB, count: 16)
        try server.publishStatus(entries: [
            (uuid: goalId, stampSec: 1, stampNanosec: 2, status: 4)
        ])
        let writes = mock.writesByTopic[server.statusTopic] ?? []
        XCTAssertEqual(writes.count, 1)
        let parsed = try ActionFrameDecoder.decodeStatusArray(from: writes[0])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].status, 4)
    }

    func testClientSendGoalAcceptedYieldsFeedback() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let clientProto = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let client = clientProto as! DDSTransportActionClientImpl

        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let goalCDR = Data([0x00, 0x01, 0x00, 0x00, 0x33, 0x44])  // umbrella-encoded (with header)

        // Pre-stage the mock to reply success on send_goal request.
        mock.serviceReplyHandler = { requestTopic, prefixedRequestCDR in
            guard requestTopic.hasSuffix("send_goalRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixedRequestCDR)
            else { return nil }
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 99, stampNanosec: 0
            )
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
        }

        let ack = try await client.sendGoal(
            goalId: goalId,
            goalCDR: goalCDR,
            acceptanceTimeout: .seconds(2)
        )
        XCTAssertTrue(ack.accepted)
        XCTAssertEqual(ack.stampSec, 99)

        // The request went out as [header | guid (8) | seq (8) | uuid[16] | bare goal] —
        // rmw_cyclonedds_cpp's 16-byte request header and no inner encapsulation header.
        let requestWrites = mock.writesByTopic[client.names.sendGoalRequestTopic] ?? []
        XCTAssertEqual(requestWrites.count, 1)
        let requestWire = Array(requestWrites[0])
        XCTAssertEqual(requestWire.count, 4 + 16 + 16 + 2)
        XCTAssertEqual(Array(requestWire.prefix(4)), [0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(Array(requestWire[20..<36]), goalId)
        XCTAssertEqual(Array(requestWire.suffix(2)), [0x33, 0x44])

        // Drive a feedback sample for that goal, shaped as a real rmw peer emits it.
        let fbFrame = Data([0x00, 0x01, 0x00, 0x00] + goalId + [0x77])
        mock.deliverSubscriberSample(topic: client.feedbackTopic, data: fbFrame)

        var receivedFB: Data?
        for await frame in ack.feedback {
            receivedFB = frame
            break
        }
        XCTAssertEqual(receivedFB, Data([0x00, 0x01, 0x00, 0x00, 0x77]))
    }

    func testClientSendGoalRejectedSurfacesAcceptedFalse() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("send_goalRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixed) else {
                return nil
            }
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: false, stampSec: 0, stampNanosec: 0)
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
        }

        let ack = try await client.sendGoal(
            goalId: [UInt8](repeating: 0xAA, count: 16),
            goalCDR: Data(),
            acceptanceTimeout: .seconds(2)
        )
        XCTAssertFalse(ack.accepted)
    }

    func testClientGetResultBlocksUntilReply() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("get_resultRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixed) else {
                return nil
            }
            let response = ActionFrameDecoder.encodeGetResultResponse(
                status: 4, resultCDR: Data([0x00, 0x01, 0x00, 0x00, 0x04, 0xAA, 0xBB])
            )
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
        }

        let ack = try await client.getResult(
            goalId: [UInt8](repeating: 0xAA, count: 16),
            timeout: .seconds(2)
        )
        XCTAssertEqual(ack.status, 4)
        // resultCDR is the whole response: [header | status | result].
        XCTAssertEqual(ack.resultCDR, Data([0x00, 0x01, 0x00, 0x00, 0x04, 0xAA, 0xBB]))
    }

    /// Regression test for a crash: `ActionGoalHandle.result(timeout: nil)`
    /// substitutes `.seconds(Int.max)` for "no timeout" and threads it down
    /// to `getResult(goalId:timeout:)`. The DDS wire timeout race used to
    /// hand that value straight to `Task.sleep(for:)`, which converts
    /// `Duration` to nanoseconds internally and traps on overflow ("Not
    /// enough bits to represent the passed value") long before any reply
    /// could arrive. The reply here is delivered from a separate `Task`
    /// after a short delay, so this also proves `getResult` genuinely waits
    /// for it rather than returning early.
    func testClientGetResultWithHugeTimeoutDoesNotTrapAndWaitsForDelayedReply() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let clientProto = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let client = clientProto as! DDSTransportActionClientImpl
        let replyTopic = client.names.getResultReplyTopic

        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("get_resultRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixed) else {
                return nil
            }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                let response = ActionFrameDecoder.encodeGetResultResponse(
                    status: 4, resultCDR: Data([0x00, 0x01, 0x00, 0x00, 0x04, 0xAA, 0xBB])
                )
                let replyWire = SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
                mock.deliver(toTopic: replyTopic, data: replyWire, timestamp: 0)
            }
            // No immediate reply — the delayed Task above delivers it.
            return nil
        }

        let ack = try await client.getResult(
            goalId: [UInt8](repeating: 0xAA, count: 16),
            timeout: .seconds(Int.max)
        )
        XCTAssertEqual(ack.status, 4)
        // resultCDR is the whole response: [header | status | result].
        XCTAssertEqual(ack.resultCDR, Data([0x00, 0x01, 0x00, 0x00, 0x04, 0xAA, 0xBB]))
    }

    /// A server sends its last feedback and then the terminal status within
    /// microseconds. Each sample used to reach the pending table from its own
    /// task, so a terminal status could overtake feedback that arrived before
    /// it and close the stream first, dropping that feedback.
    func testClientFeedbackBeforeTerminalStatusIsDeliveredInOrder() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try makeClient(session)
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let ack = try await sendAcceptedGoal(client, mock: mock, goalId: goalId)

        let count = 200
        for i in 0..<count {
            let frame = Data([0x00, 0x01, 0x00, 0x00] + goalId + [UInt8(i)])
            mock.deliverSubscriberSample(topic: client.feedbackTopic, data: frame)
        }
        let terminal = ActionFrameDecoder.encodeStatusArray(entries: [
            (uuid: goalId, stampSec: 0, stampNanosec: 0, status: 4)
        ])
        mock.deliverSubscriberSample(topic: client.statusTopic, data: terminal)

        var received: [UInt8] = []
        for await fb in ack.feedback {
            received.append(fb.last ?? 0)
        }
        XCTAssertEqual(received, (0..<count).map { UInt8($0) })
        var statuses: [Int8] = []
        for await update in ack.status {
            statuses.append(update.status)
        }
        XCTAssertEqual(statuses, [4])
    }

    /// The get_result reply can reach the client right behind the last
    /// feedback: the server answers it before it publishes the terminal
    /// status. Ending the goal must not overtake feedback received before
    /// the reply.
    func testClientGetResultKeepsFeedbackReceivedBeforeTheReply() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try makeClient(session)
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let ack = try await sendAcceptedGoal(client, mock: mock, goalId: goalId)

        let count = 200
        for i in 0..<count {
            let frame = Data([0x00, 0x01, 0x00, 0x00] + goalId + [UInt8(i)])
            mock.deliverSubscriberSample(topic: client.feedbackTopic, data: frame)
        }
        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("get_resultRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixed) else {
                return nil
            }
            let response = ActionFrameDecoder.encodeGetResultResponse(
                status: 4, resultCDR: Data([0x00, 0x01, 0x00, 0x00, 0x04]))
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
        }
        let result = try await client.getResult(goalId: goalId, timeout: .seconds(2))
        XCTAssertEqual(result.status, 4)

        var received: [UInt8] = []
        for await fb in ack.feedback {
            received.append(fb.last ?? 0)
        }
        XCTAssertEqual(received, (0..<count).map { UInt8($0) })
    }

    /// Closing the client finishes the inbound stream: a barrier after close
    /// returns instead of waiting for a pump that is gone, and samples that
    /// arrive late are dropped without a trace.
    func testClientDrainAfterCloseDoesNotHangAndLateSamplesAreDropped() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try makeClient(session)
        let goalId = [UInt8](repeating: 0xAA, count: 16)
        let ack = try await sendAcceptedGoal(client, mock: mock, goalId: goalId)

        try client.close()
        await client.drainInbound()
        client.handleFeedbackSample(data: Data([0x00, 0x01, 0x00, 0x00] + goalId + [0x01]))
        await client.drainInbound()

        var received = 0
        for await _ in ack.feedback { received += 1 }
        XCTAssertEqual(received, 0)
    }

    func testClientStatusFiltersByGoalId() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let clientProto = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let client = clientProto as! DDSTransportActionClientImpl
        let myGoal = [UInt8](repeating: 0xAA, count: 16)
        let otherGoal = [UInt8](repeating: 0xBB, count: 16)

        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("send_goalRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixed) else {
                return nil
            }
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 0, stampNanosec: 0)
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
        }
        let ack = try await client.sendGoal(
            goalId: myGoal,
            goalCDR: Data(),
            acceptanceTimeout: .seconds(2)
        )
        XCTAssertTrue(ack.accepted)

        // Push a status array containing both my goal and another goal.
        let frame = ActionFrameDecoder.encodeStatusArray(entries: [
            (uuid: otherGoal, stampSec: 0, stampNanosec: 0, status: 2),
            (uuid: myGoal, stampSec: 0, stampNanosec: 0, status: 1),
            (uuid: myGoal, stampSec: 0, stampNanosec: 0, status: 4),
        ])
        mock.deliverSubscriberSample(topic: client.statusTopic, data: frame)

        var seen: [Int8] = []
        for await update in ack.status {
            seen.append(update.status)
        }
        // Other-goal status filtered out; mine arrive in order; terminal closes the stream.
        XCTAssertEqual(seen, [1, 4])
    }

    // MARK: - Helpers

    private func defaultHashes() -> ActionRoleTypeHashes {
        return ActionRoleTypeHashes(
            sendGoalRequest: nil, sendGoalResponse: nil,
            cancelGoalRequest: nil, cancelGoalResponse: nil,
            getResultRequest: nil, getResultResponse: nil,
            feedbackMessage: nil, statusArray: nil
        )
    }

    /// Poll the mock until at least one write has landed on `topic` or the
    /// timeout elapses. Detached server tasks may write the reply slightly
    /// after the handler returns, so a tiny poll is necessary.
    private func waitForWrite(
        mock: MockDDSClient, topic: String, timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entries = mock.writesByTopic[topic], !entries.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testClientWaitForActionServerThrowsWhenNoMatch() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        // Default mock never reports a publication match → must time out.
        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        do {
            try await client.waitForActionServer(timeout: .milliseconds(300))
            XCTFail("expected actionServerUnavailable")
        } catch let e as TransportError {
            if case .actionServerUnavailable = e { return }
            XCTFail("got \(e) instead of actionServerUnavailable")
        }
    }

    func testClientWaitForActionServerSucceedsWhenAllWritersMatch() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        // Mark every request writer and reply reader as matched so the
        // all-3-service-pairs wait condition resolves on the first poll.
        let cli = client as! DDSTransportActionClientImpl
        mock.markPublicationsMatched(topic: cli.names.sendGoalRequestTopic)
        mock.markPublicationsMatched(topic: cli.names.cancelGoalRequestTopic)
        mock.markPublicationsMatched(topic: cli.names.getResultRequestTopic)
        mock.markSubscriptionsMatched(topic: cli.names.sendGoalReplyTopic)
        mock.markSubscriptionsMatched(topic: cli.names.cancelGoalReplyTopic)
        mock.markSubscriptionsMatched(topic: cli.names.getResultReplyTopic)

        try await client.waitForActionServer(timeout: .seconds(2))  // no throw expected
    }

    /// Regression: with only the request writers matched, the server's reply
    /// writers may not have matched our reply readers yet, so the first
    /// `send_goal` reply would be lost. The wait must hold until every reply
    /// reader has matched too.
    func testClientWaitForActionServerWaitsForReplyReaders() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let cli = client as! DDSTransportActionClientImpl
        mock.markPublicationsMatched(topic: cli.names.sendGoalRequestTopic)
        mock.markPublicationsMatched(topic: cli.names.cancelGoalRequestTopic)
        mock.markPublicationsMatched(topic: cli.names.getResultRequestTopic)
        mock.markSubscriptionsMatched(topic: cli.names.sendGoalReplyTopic)
        mock.markSubscriptionsMatched(topic: cli.names.cancelGoalReplyTopic)

        do {
            try await client.waitForActionServer(timeout: .milliseconds(300))
            XCTFail("expected actionServerUnavailable while get_result's reply reader is unmatched")
        } catch let e as TransportError {
            guard case .actionServerUnavailable = e else {
                return XCTFail("got \(e) instead of actionServerUnavailable")
            }
        }

        mock.markSubscriptionsMatched(topic: cli.names.getResultReplyTopic)
        try await client.waitForActionServer(timeout: .seconds(2))
    }

    /// Each service pair of the action client carries its own rmw_cyclonedds_cpp
    /// `clientid` on both its request writer and its reply reader.
    func testClientServicePairsCarryClientIds() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let names = (client as! DDSTransportActionClientImpl).names
        func clientId(_ userData: String?) -> String? {
            guard let ud = userData, ud.hasPrefix("clientid=") else { return nil }
            return ud.split(separator: ";").first.map(String.init)
        }
        var ids: [String] = []
        for (request, reply) in [
            (names.sendGoalRequestTopic, names.sendGoalReplyTopic),
            (names.cancelGoalRequestTopic, names.cancelGoalReplyTopic),
            (names.getResultRequestTopic, names.getResultReplyTopic),
        ] {
            let w = try XCTUnwrap(mock.writers.first { $0.topic == request })
            let r = try XCTUnwrap(mock.readers.first { $0.topic == reply })
            let wid = try XCTUnwrap(clientId(w.userData), "request writer \(request) has no clientid")
            XCTAssertEqual(clientId(r.userData), wid, "reply reader \(reply) must share the clientid")
            ids.append(wid)
        }
        XCTAssertEqual(Set(ids).count, 3, "each service pair needs its own clientid")
        // Feedback / status readers are not service endpoints.
        XCTAssertNil(clientId(mock.readers.first { $0.topic == names.feedbackTopic }?.userData))
        XCTAssertNil(clientId(mock.readers.first { $0.topic == names.statusTopic }?.userData))
    }

    func testClientCancelGoalRoundTrip() async throws {
        let mock = MockDDSClient()
        let session = DDSTransportSession(client: mock)
        try await session.open(config: .ddsMulticast(domainId: 0))
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        let goalId = [UInt8](repeating: 0xAA, count: 16)

        // Server replies returnCode=0 with one canceling goal entry.
        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("cancel_goalRequest") else { return nil }
            let (rid, _) =
                (try? SampleIdentityPrefix.decode(wirePayload: prefixed))
                ?? (RMWRequestId(writerGuid: [UInt8](repeating: 0, count: 8), sequenceNumber: 0), Data())
            // [header (4) | code (1) | pad (3) | count (u32) | { uuid[16] | sec | nsec }]
            var resp = Data([0x00, 0x01, 0x00, 0x00])
            resp.append(0)  // returnCode = 0
            resp.append(contentsOf: [0, 0, 0])
            var count = UInt32(1).littleEndian
            withUnsafeBytes(of: &count) { resp.append(contentsOf: $0) }
            resp.append(contentsOf: goalId)
            var sec = Int32(7).littleEndian
            var nsec = UInt32(11).littleEndian
            withUnsafeBytes(of: &sec) { resp.append(contentsOf: $0) }
            withUnsafeBytes(of: &nsec) { resp.append(contentsOf: $0) }
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: resp)
        }

        let ack = try await client.cancelGoal(
            goalId: goalId,
            beforeStampSec: nil,
            beforeStampNanosec: nil,
            timeout: .seconds(2)
        )
        XCTAssertEqual(ack.returnCode, 0)
        XCTAssertEqual(ack.goalsCanceling.count, 1)
        XCTAssertEqual(ack.goalsCanceling[0].uuid, goalId)
        XCTAssertEqual(ack.goalsCanceling[0].stampSec, 7)
        XCTAssertEqual(ack.goalsCanceling[0].stampNanosec, 11)

        // Confirm the request that went out on the wire carried the goal id.
        let cancelTopic = (client as! DDSTransportActionClientImpl).names.cancelGoalRequestTopic
        let writes = mock.writesByTopic[cancelTopic] ?? []
        XCTAssertEqual(writes.count, 1)
        let (_, reqCDR) = try SampleIdentityPrefix.decode(wirePayload: writes[0])
        // Request frame: [header (4) | uuid[16] | sec | nsec]
        XCTAssertEqual(reqCDR.count, 4 + 16 + 4 + 4)
        XCTAssertEqual(
            Array(reqCDR[(reqCDR.startIndex + 4)..<(reqCDR.startIndex + 20)]), goalId)
    }

    fileprivate func makeClient(_ session: DDSTransportSession) throws -> DDSTransportActionClientImpl {
        let client = try session.createActionClient(
            name: "/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: defaultHashes(),
            qos: .default
        )
        return client as! DDSTransportActionClientImpl
    }

    /// Sends one goal that the mock server accepts.
    fileprivate func sendAcceptedGoal(
        _ client: DDSTransportActionClientImpl, mock: MockDDSClient, goalId: [UInt8]
    ) async throws -> SendGoalAck {
        mock.serviceReplyHandler = { topic, prefixed in
            guard topic.hasSuffix("send_goalRequest") else { return nil }
            guard let (rid, _) = try? SampleIdentityPrefix.decode(wirePayload: prefixed) else {
                return nil
            }
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 0, stampNanosec: 0)
            return SampleIdentityPrefix.encode(requestId: rid, userCDR: response)
        }
        let ack = try await client.sendGoal(goalId: goalId, goalCDR: Data(), acceptanceTimeout: .seconds(2))
        XCTAssertTrue(ack.accepted)
        return ack
    }
}
