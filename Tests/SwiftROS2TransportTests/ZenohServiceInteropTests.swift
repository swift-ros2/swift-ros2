// ZenohServiceInteropTests.swift
// The wire Zenoh services and actions as rmw_zenoh_cpp keys, announces and answers them.

import Foundation
import SwiftROS2Wire
import XCTest

@testable import SwiftROS2Transport

final class ZenohServiceInteropTests: XCTestCase {
    static let triggerServiceHash = "RIHS01_eeff2cd6fa5ad9d27cdf4dec64818317839b62f212a91e6b5304b634b2062c5f"
    static let triggerRequestHash = "RIHS01_aaa"
    static let qos = QoSPolicy(
        reliability: .reliable, durability: .volatile, historyPolicy: .keepLast, historyDepth: 10
    )
    .toKeyExpr()

    private func openSession(
        _ mock: MockZenohClient, distro: ROS2Distro = .lyrical
    ) async throws -> ZenohTransportSession {
        let session = ZenohTransportSession(client: mock)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 123, wireMode: distro))
        return session
    }

    private func makeTriggerServer(
        _ session: ZenohTransportSession,
        serviceTypeHash: String? = triggerServiceHash,
        node: String? = "swift_node",
        name: String = "/e2e/trigger"
    ) throws -> any TransportService {
        try session.createServiceServer(
            name: name,
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: Self.triggerRequestHash,
            responseTypeHash: "RIHS01_bbb",
            serviceTypeHash: serviceTypeHash,
            qos: TransportQoS(),
            nodeName: node,
            nodeNamespace: "/e2e",
            handler: { _ in Data([0x00, 0x01, 0x00, 0x00, 0x01]) }
        )
    }

    // MARK: - Service server

    func testServerKeyAndTokenMatchRmwZenoh() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        _ = try makeTriggerServer(session)

        XCTAssertEqual(
            mock.queryableDeclarations.map(\.key),
            ["123/e2e/trigger/std_srvs::srv::dds_::Trigger_/\(Self.triggerServiceHash)"])
        XCTAssertEqual(mock.declaredLivelinessTokens.count, 1)
        let token = try XCTUnwrap(mock.declaredLivelinessTokens.first)
        let parts = token.split(separator: "/").map(String.init)
        XCTAssertEqual(parts[0], "@ros2_lv")
        XCTAssertEqual(parts[1], "123")
        XCTAssertEqual(parts[2], "mock-session-id")
        XCTAssertEqual(parts[5], "SS")
        XCTAssertEqual(
            Array(parts[6...]),
            [
                "%", "%e2e", "swift_node", "%e2e%trigger", "std_srvs::srv::dds_::Trigger_", Self.triggerServiceHash,
                Self.qos,
            ])
    }

    func testHumbleServerUsesPlaceholderHash() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock, distro: .humble)
        defer { try? session.close() }

        _ = try makeTriggerServer(session, serviceTypeHash: nil)

        XCTAssertEqual(
            mock.queryableDeclarations.map(\.key),
            ["123/e2e/trigger/std_srvs::srv::dds_::Trigger_/TypeHashNotSupported"])
        XCTAssertTrue(
            mock.declaredLivelinessTokens[0].hasSuffix(
                "/SS/%/%e2e/swift_node/%e2e%trigger/std_srvs::srv::dds_::Trigger_/TypeHashNotSupported/\(Self.qos)"))
    }

    func testServerWithoutServiceHashFallsBackToRequestKey() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        _ = try makeTriggerServer(session, serviceTypeHash: nil)

        XCTAssertEqual(
            mock.queryableDeclarations.map(\.key),
            ["123/e2e/trigger/std_srvs::srv::dds_::Trigger_Request_/\(Self.triggerRequestHash)"])
        XCTAssertTrue(
            mock.declaredLivelinessTokens[0].contains(
                "/%e2e%trigger/std_srvs::srv::dds_::Trigger_Request_/\(Self.triggerRequestHash)/"))
    }

    func testFallbackIsLoggedOncePerType() {
        let log = ZenohServiceHashFallbackLog()
        XCTAssertTrue(log.reportOnce(typeName: "pkg/srv/A"))
        XCTAssertFalse(log.reportOnce(typeName: "pkg/srv/A"))
        XCTAssertTrue(log.reportOnce(typeName: "pkg/srv/B"))
    }

    func testServiceNamingResolution() {
        let service = "std_srvs::srv::dds_::Trigger_"
        let request = "std_srvs::srv::dds_::Trigger_Request_"
        XCTAssertEqual(
            ZenohServiceNaming.resolve(
                distro: .jazzy, serviceDDSTypeName: service, serviceTypeHash: "S",
                requestDDSTypeName: request, requestTypeHash: "R"),
            ZenohServiceNaming(ddsTypeName: service, typeHash: "S", isLegacy: false))
        XCTAssertEqual(
            ZenohServiceNaming.resolve(
                distro: .jazzy, serviceDDSTypeName: service, serviceTypeHash: nil,
                requestDDSTypeName: request, requestTypeHash: "R"),
            ZenohServiceNaming(ddsTypeName: request, typeHash: "R", isLegacy: true))
        XCTAssertEqual(
            ZenohServiceNaming.resolve(
                distro: .jazzy, serviceDDSTypeName: service, serviceTypeHash: nil,
                requestDDSTypeName: request, requestTypeHash: nil),
            ZenohServiceNaming(ddsTypeName: service, typeHash: nil, isLegacy: false))
        XCTAssertEqual(
            ZenohServiceNaming.resolve(
                distro: .humble, serviceDDSTypeName: service, serviceTypeHash: nil,
                requestDDSTypeName: request, requestTypeHash: "R"),
            ZenohServiceNaming(ddsTypeName: service, typeHash: nil, isLegacy: false))
    }

    func testServerReplyEchoesRequestSequenceAndGid() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        _ = try makeTriggerServer(session)

        let gid = [UInt8](1...16)
        let request = ZenohWireCodec(distro: .lyrical).buildAttachment(seq: 42, tsNsec: 1_000, gid: gid)
        mock.deliverQueryToQueryable(
            keyExpr: mock.queryableDeclarations[0].key, payload: Data([0x00, 0x01, 0x00, 0x00]),
            attachment: request)
        try await mock.awaitQueryReply(timeout: .seconds(1))

        let reply = try XCTUnwrap(mock.deliveredQueries.last?.replyAttachment)
        XCTAssertEqual(reply.count, 33)
        XCTAssertEqual(Array(reply[0..<8]), Array(request[0..<8]), "sequence number")
        XCTAssertEqual(Array(reply[16..<33]), Array(request[16..<33]), "GID")
    }

    func testServerReplyWithoutRequestAttachmentHasNone() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        _ = try makeTriggerServer(session)

        mock.deliverQueryToQueryable(
            keyExpr: mock.queryableDeclarations[0].key, payload: Data([0x00, 0x01, 0x00, 0x00]), attachment: nil)
        try await mock.awaitQueryReply(timeout: .seconds(1))
        XCTAssertNotNil(mock.lastQueryReplyPayload)
        XCTAssertNil(mock.deliveredQueries.last?.replyAttachment)
    }

    func testServerCloseDropsToken() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        let server = try makeTriggerServer(session)
        try server.close()
        XCTAssertEqual(mock.livelinessHandles.map(\.closeCount), [1])
    }

    // MARK: - Node identity

    func testEntitiesOfOneNodeShareTheNodeId() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        _ = try makeTriggerServer(session, name: "/e2e/a")
        _ = try makeTriggerServer(session, name: "/e2e/b")
        _ = try makeTriggerServer(session, node: "other_node", name: "/e2e/c")

        let ids = mock.declaredLivelinessTokens.map { token -> (node: String, entity: String) in
            let parts = token.split(separator: "/").map(String.init)
            return (parts[3], parts[4])
        }
        XCTAssertEqual(ids[0].node, ids[1].node)
        XCTAssertNotEqual(ids[0].node, ids[2].node)
        XCTAssertEqual(Set(ids.map(\.entity)).count, 3)
        XCTAssertTrue(mock.declaredLivelinessTokens[2].contains("/SS/%/%e2e/other_node/"))
    }

    func testNodeNamespaceIsNormalized() {
        XCTAssertEqual(ZenohNodeIdentity.normalizedNamespace(nil), "/")
        XCTAssertEqual(ZenohNodeIdentity.normalizedNamespace(""), "/")
        XCTAssertEqual(ZenohNodeIdentity.normalizedNamespace("/"), "/")
        XCTAssertEqual(ZenohNodeIdentity.normalizedNamespace("e2e/"), "/e2e")
        XCTAssertEqual(ZenohNodeIdentity.normalizedNamespace("/a/b"), "/a/b")
    }

    // MARK: - Service client

    func testClientSendsAttachmentAndDeclaresToken() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        let client = try session.createServiceClient(
            name: "/e2e/trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: Self.triggerRequestHash,
            responseTypeHash: nil,
            serviceTypeHash: Self.triggerServiceHash,
            qos: TransportQoS(),
            nodeName: "swift_node",
            nodeNamespace: "/e2e"
        )
        XCTAssertTrue(
            mock.declaredLivelinessTokens[0].contains(
                "/SC/%/%e2e/swift_node/%e2e%trigger/std_srvs::srv::dds_::Trigger_/\(Self.triggerServiceHash)/"))

        mock.scriptGetReply(payload: Data([0x00, 0x01, 0x00, 0x00]), isError: false)
        mock.scriptGetReply(payload: Data([0x00, 0x01, 0x00, 0x00]), isError: false)
        _ = try await client.call(requestCDR: Data([0x00, 0x01, 0x00, 0x00]), timeout: .seconds(1))
        _ = try await client.call(requestCDR: Data([0x00, 0x01, 0x00, 0x00]), timeout: .seconds(1))

        XCTAssertEqual(mock.gets.map(\.key), Array(repeating: mock.gets[0].key, count: 2))
        XCTAssertEqual(mock.gets[0].key, "123/e2e/trigger/std_srvs::srv::dds_::Trigger_/\(Self.triggerServiceHash)")
        let first = try XCTUnwrap(mock.gets[0].attachment)
        let second = try XCTUnwrap(mock.gets[1].attachment)
        XCTAssertEqual(first.count, 33)
        XCTAssertEqual(Array(first[0..<8]), [1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(second[0..<8]), [2, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(first[16..<33]), Array(second[16..<33]))
        // The GID rmw_zenoh_cpp derives from the client's SC token.
        XCTAssertEqual(
            Array(first[17..<33]), ZenohWireCodec.entityGid(livelinessToken: mock.declaredLivelinessTokens[0]))
    }

    func testClientsGetDistinctGids() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        for _ in 0..<2 {
            let client = try session.createServiceClient(
                name: "/e2e/trigger", serviceTypeName: "std_srvs/srv/Trigger", requestTypeHash: nil,
                responseTypeHash: nil, qos: TransportQoS())
            mock.scriptGetReply(payload: Data([0x00, 0x01, 0x00, 0x00]), isError: false)
            _ = try await client.call(requestCDR: Data([0x00, 0x01, 0x00, 0x00]), timeout: .seconds(1))
        }
        XCTAssertNotEqual(mock.gets[0].attachment?[17...], mock.gets[1].attachment?[17...])
    }

    func testWaitForServiceQueriesServerTokens() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        let client = try session.createServiceClient(
            name: "/e2e/trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: Self.triggerRequestHash,
            responseTypeHash: nil,
            serviceTypeHash: Self.triggerServiceHash,
            qos: TransportQoS(),
            nodeName: "swift_node",
            nodeNamespace: "/e2e"
        )
        do {
            try await client.waitForService(timeout: .milliseconds(250))
            XCTFail("no server yet: expected a timeout")
        } catch TransportError.connectionTimeout {}
        XCTAssertEqual(
            mock.livelinessGets.first,
            "@ros2_lv/123/*/*/*/SS/*/*/*/%e2e%trigger/std_srvs::srv::dds_::Trigger_/**")
        XCTAssertTrue(mock.gets.isEmpty, "discovery must not send requests without an attachment")

        // An rclpy server on another node of another session.
        mock.remoteLivelinessTokens = [
            "@ros2_lv/123/0a1b/3/12/SS/%/%e2e/host_node/%e2e%trigger/std_srvs::srv::dds_::Trigger_/"
                + "\(Self.triggerServiceHash)/::,10:,:,:,,"
        ]
        try await client.waitForService(timeout: .seconds(1))
    }

    func testWaitForServiceFindsServerOfTheSameSession() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        let client = try session.createServiceClient(
            name: "/e2e/trigger", serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: Self.triggerRequestHash, responseTypeHash: nil,
            serviceTypeHash: Self.triggerServiceHash, qos: TransportQoS(), nodeName: "c", nodeNamespace: "/")
        _ = try makeTriggerServer(session)
        try await client.waitForService(timeout: .seconds(1))
    }

    // MARK: - Actions

    private func fibonacciHashes() -> ActionRoleTypeHashes {
        ActionRoleTypeHashes(
            sendGoalRequest: "RIHS01_sgreq", sendGoalResponse: nil,
            cancelGoalRequest: "RIHS01_cgreq", cancelGoalResponse: nil,
            getResultRequest: "RIHS01_grreq", getResultResponse: nil,
            feedbackMessage: "RIHS01_fb", statusArray: "RIHS01_st",
            sendGoalService: "RIHS01_sg", cancelGoalService: "RIHS01_cg", getResultService: "RIHS01_gr"
        )
    }

    private func makeActionServer(
        _ session: ZenohTransportSession, hashes: ActionRoleTypeHashes
    ) throws -> ZenohTransportActionServerImpl {
        try session.createActionServer(
            name: "/e2e/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: hashes,
            qos: TransportQoS(),
            nodeName: "swift_node",
            nodeNamespace: "/e2e",
            handlers: TransportActionServerHandlers(
                onSendGoal: { _, _ in (true, 1, 2) },
                onCancelGoal: { _ in Data([0x00, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]) },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data([0x00, 0x01, 0x00, 0x00])) }
            )
        ) as! ZenohTransportActionServerImpl
    }

    func testActionServerKeysAndTokensMatchRmwZenoh() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        let server = try makeActionServer(session, hashes: fibonacciHashes())

        let base = "123/e2e/fibonacci/_action"
        XCTAssertEqual(
            mock.queryableDeclarations.map(\.key),
            [
                "\(base)/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/RIHS01_sg",
                "\(base)/cancel_goal/action_msgs::srv::dds_::CancelGoal_/RIHS01_cg",
                "\(base)/get_result/example_interfaces::action::dds_::Fibonacci_GetResult_/RIHS01_gr",
            ])
        XCTAssertEqual(
            server.feedbackKeyExpr,
            "\(base)/feedback/example_interfaces::action::dds_::Fibonacci_FeedbackMessage_/RIHS01_fb")
        XCTAssertEqual(server.statusKeyExpr, "\(base)/status/action_msgs::msg::dds_::GoalStatusArray_/RIHS01_st")

        // The tail of each token after the node identity: kind, name, type, hash, QoS.
        let tails = mock.declaredLivelinessTokens.map { token -> String in
            let parts = token.split(separator: "/").map(String.init)
            XCTAssertEqual(Array(parts[6...8]), ["%", "%e2e", "swift_node"])
            return ([parts[5]] + parts[9...]).joined(separator: "/")
        }
        let statusQoS = QoSPolicy(
            reliability: .reliable, durability: .transientLocal, historyPolicy: .keepLast, historyDepth: 1
        ).toKeyExpr()
        let mangled = "%e2e%fibonacci%_action"
        XCTAssertEqual(
            tails,
            [
                "SS/\(mangled)%send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/RIHS01_sg/\(Self.qos)",
                "SS/\(mangled)%cancel_goal/action_msgs::srv::dds_::CancelGoal_/RIHS01_cg/\(Self.qos)",
                "SS/\(mangled)%get_result/example_interfaces::action::dds_::Fibonacci_GetResult_/RIHS01_gr/\(Self.qos)",
                "MP/\(mangled)%feedback/example_interfaces::action::dds_::Fibonacci_FeedbackMessage_/RIHS01_fb/\(Self.qos)",
                "MP/\(mangled)%status/action_msgs::msg::dds_::GoalStatusArray_/RIHS01_st/\(statusQoS)",
            ])
        XCTAssertFalse(mock.declaredLivelinessTokens.contains { $0.contains("/SA/") || $0.contains("/CA/") })
    }

    func testHumbleActionKeysUsePlaceholder() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock, distro: .humble)
        defer { try? session.close() }
        let none = ActionRoleTypeHashes(
            sendGoalRequest: nil, sendGoalResponse: nil, cancelGoalRequest: nil, cancelGoalResponse: nil,
            getResultRequest: nil, getResultResponse: nil, feedbackMessage: nil, statusArray: nil)
        let server = try makeActionServer(session, hashes: none)
        XCTAssertEqual(
            mock.queryableDeclarations[0].key,
            "123/e2e/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/TypeHashNotSupported"
        )
        XCTAssertEqual(
            server.statusKeyExpr,
            "123/e2e/fibonacci/_action/status/action_msgs::msg::dds_::GoalStatusArray_/TypeHashNotSupported")
    }

    func testActionWithoutServiceHashesFallsBackToRequestKeys() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        let legacy = ActionRoleTypeHashes(
            sendGoalRequest: "RIHS01_sgreq", sendGoalResponse: nil, cancelGoalRequest: "RIHS01_cgreq",
            cancelGoalResponse: nil, getResultRequest: "RIHS01_grreq", getResultResponse: nil,
            feedbackMessage: "RIHS01_fb", statusArray: "RIHS01_st")
        _ = try makeActionServer(session, hashes: legacy)
        XCTAssertEqual(
            mock.queryableDeclarations.map(\.key),
            [
                "123/e2e/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_Request_/RIHS01_sgreq",
                "123/e2e/fibonacci/_action/cancel_goal/action_msgs::srv::dds_::CancelGoal_Request_/RIHS01_cgreq",
                "123/e2e/fibonacci/_action/get_result/example_interfaces::action::dds_::Fibonacci_GetResult_Request_/RIHS01_grreq",
            ])
    }

    func testActionServerRepliesEchoAttachments() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }
        let server = try makeActionServer(session, hashes: fibonacciHashes())

        let request = ZenohWireCodec(distro: .lyrical).buildAttachment(
            seq: 9, tsNsec: 5, gid: [UInt8](repeating: 0x42, count: 16))
        let goalFrame = Data([0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0xAA, count: 16) + [5, 0, 0, 0])
        let resultFrame = Data([0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0xAA, count: 16))
        for (key, frame) in [(server.sendGoalKeyExpr, goalFrame), (server.getResultKeyExpr, resultFrame)] {
            let replies = try await mock.deliverQuery(keyExpr: key, payload: frame, attachment: request)
            XCTAssertEqual(replies.count, 1, key)
            let reply = try XCTUnwrap(mock.deliveredQueries.last?.replyAttachment, key)
            XCTAssertEqual(Array(reply[0..<8]), Array(request[0..<8]), key)
            XCTAssertEqual(Array(reply[16..<33]), Array(request[16..<33]), key)
        }
    }

    func testActionClientTokensAttachmentsAndDiscovery() async throws {
        let mock = MockZenohClient()
        let session = try await openSession(mock)
        defer { try? session.close() }

        let client = try session.createActionClient(
            name: "/e2e/fibonacci",
            actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: fibonacciHashes(),
            qos: TransportQoS(),
            nodeName: "swift_client",
            nodeNamespace: "/e2e"
        )
        let kinds = mock.declaredLivelinessTokens.map { $0.split(separator: "/").map(String.init)[5] }
        XCTAssertEqual(kinds, ["SC", "SC", "SC", "MS", "MS"])

        do {
            try await client.waitForActionServer(timeout: .milliseconds(250))
            XCTFail("expected actionServerUnavailable")
        } catch TransportError.actionServerUnavailable {}
        XCTAssertTrue(mock.gets.isEmpty, "discovery must not send requests without an attachment")

        // A server with only send_goal announced is not available yet.
        let prefix = "@ros2_lv/123/0a1b/3"
        let mangled = "%e2e%fibonacci%_action"
        mock.remoteLivelinessTokens = [
            "\(prefix)/10/SS/%/%e2e/host/\(mangled)%send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/RIHS01_sg/q"
        ]
        do {
            try await client.waitForActionServer(timeout: .milliseconds(250))
            XCTFail("expected actionServerUnavailable")
        } catch TransportError.actionServerUnavailable {}
        mock.remoteLivelinessTokens += [
            "\(prefix)/11/SS/%/%e2e/host/\(mangled)%cancel_goal/action_msgs::srv::dds_::CancelGoal_/RIHS01_cg/q",
            "\(prefix)/12/SS/%/%e2e/host/\(mangled)%get_result/example_interfaces::action::dds_::Fibonacci_GetResult_/RIHS01_gr/q",
        ]
        try await client.waitForActionServer(timeout: .seconds(1))

        mock.scriptGetReply(
            payload: Data([0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]), isError: false)
        _ = try await client.sendGoal(
            goalId: [UInt8](repeating: 1, count: 16), goalCDR: Data([0x00, 0x01, 0x00, 0x00, 5, 0, 0, 0]),
            acceptanceTimeout: .seconds(1))
        let get = try XCTUnwrap(mock.gets.last)
        XCTAssertEqual(
            get.key,
            "123/e2e/fibonacci/_action/send_goal/example_interfaces::action::dds_::Fibonacci_SendGoal_/RIHS01_sg")
        XCTAssertEqual(get.attachment?.count, 33)
        XCTAssertEqual(get.attachment.map { Array($0[0..<8]) }, [1, 0, 0, 0, 0, 0, 0, 0])
        // Requests carry the GID of the send_goal client (its SC token).
        XCTAssertEqual(
            get.attachment.map { Array($0[17..<33]) },
            ZenohWireCodec.entityGid(livelinessToken: mock.declaredLivelinessTokens[0]))
    }
}
