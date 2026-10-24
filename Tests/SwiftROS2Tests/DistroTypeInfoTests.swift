// DistroTypeInfoTests.swift
// Entities send each type with the layout and type hash of the context's distribution.
//
// The fixture `distro_test_msgs` (Tests/FixtureIDL) is generated from a Jazzy and a Lyrical copy
// of its IDL: Lyrical adds `float64 smoothness` to `Plan`, so `Plan`, `ExecutePlan_Request`, the
// `ExecutePlan` service and the `FollowPlan` goal wrappers have one hash up to Kilted and another
// from Lyrical on (Rolling takes Lyrical's), and `smoothness` is on the wire from Lyrical on only.

import Foundation
import SwiftROS2TestFixtures
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Messages
@testable import SwiftROS2Transport

/// The fixture hashes, copied from the generated `typeInfo(for:)` of each type.
enum DistroFixture {
    static let planJazzy = "RIHS01_8979d76e14d004cf09bee9522b2311d20a3e5f40af5b965e599986608e33108e"
    static let planLyrical = "RIHS01_6f3faec5d6aae8e908e370ea51647a0491304ccbd73615cc4bfad06616dbc8d4"

    static let requestJazzy = "RIHS01_d984ea1b10e2756f76d292a5e2d7dd2ab5cb8cd51a380435504998d44031e642"
    static let requestLyrical = "RIHS01_58102be99a2602919f962d7d98ccd772385cdace740f90870d5f995ec3a9adee"
    static let response = "RIHS01_baea74828d030984e4362a962cc2f0043e7d13f6afa3bc58040d9c2312c62eaa"
    static let serviceJazzy = "RIHS01_669587d832d713424aafcf5d34e0806aba49a5250144ceff114d01df351ebc78"
    static let serviceLyrical = "RIHS01_c1987bd580e8dd984c4df57a5dc2c617443a18e28a29bdf1e9578e7a6c147d91"

    static let sendGoalRequestJazzy = "RIHS01_3d1fcce206fff4faf78e526c42d57ff327d118987dca0bfcad284b7381b33550"
    static let sendGoalRequestLyrical = "RIHS01_d1bb9c60f42783db59642cd73733667900b75514e47774b0bd4d763bd7c29932"
    static let sendGoalServiceJazzy = "RIHS01_f861793bfa5537a53950709c3f3df75e61a979a311ea4e43f6339fd05663da28"
    static let sendGoalServiceLyrical = "RIHS01_d85e3322bf7250318ae58b2f6e4ed8c13e8959d0888c76078da1bcc5dc8e2415"
    static let getResultService = "RIHS01_2b1723701cd9371fe01db308806a1c21a81496a36b6a74b57cccb62fa602f77d"
    static let feedbackMessage = "RIHS01_f78abe369ca2fa62b997068ac4918c28a918bba6d676bedf64d268704114c160"

    /// Whether `distro` has Lyrical's `Plan` (`smoothness` on the wire).
    static func hasSmoothness(_ distro: ROS2Distro) -> Bool { distro >= .lyrical }

    /// The value `jazzy` or `lyrical` for a distribution with hashes, nil on Humble.
    static func pick(_ distro: ROS2Distro, jazzy: String, lyrical: String) -> String? {
        guard distro.supportsTypeHash else { return nil }
        return hasSmoothness(distro) ? lyrical : jazzy
    }

    static let plan = Plan(speed: 1.5, smoothness: -2.25)

    /// `plan` as CDR (with the encapsulation header): `speed` = 1.5, then `smoothness` = -2.25
    /// where the distribution has it.
    static func planBytes(_ distro: ROS2Distro) -> [UInt8] {
        header + planBody(distro)
    }

    static func planBody(_ distro: ROS2Distro) -> [UInt8] {
        let speed: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F]
        let smoothness: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xC0]
        return hasSmoothness(distro) ? speed + smoothness : speed
    }

    static let header: [UInt8] = [0x00, 0x01, 0x00, 0x00]

    /// The Plan a receiver on `distro` decodes from ``planBytes(_:)``.
    static func decodedPlan(_ distro: ROS2Distro) -> Plan {
        Plan(speed: 1.5, smoothness: hasSmoothness(distro) ? -2.25 : 0.0)
    }
}

private struct RecordingFollowPlanHandler: ActionServerHandler {
    typealias Action = FollowPlanAction
    let goals: Box<[FollowPlanAction.Goal]>

    func handleGoal(_ goal: FollowPlanAction.Goal) async -> GoalResponse {
        goals.mutate { $0.append(goal) }
        return .reject
    }

    func handleCancel(_ handle: ActionGoalHandle<FollowPlanAction>) async -> CancelResponse { .reject }

    func execute(_ handle: ActionGoalHandle<FollowPlanAction>) async throws -> FollowPlanAction.Result {
        FollowPlanAction.Result()
    }
}

private func makeContext(_ distro: ROS2Distro, session: any TransportSession) async throws -> ROS2Context {
    try await ROS2Context(
        transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0), distro: distro, session: session)
}

private func makeNode(_ ctx: ROS2Context) async throws -> ROS2Node {
    try await ctx.createNode(name: "distro_node", options: ROS2NodeOptions(startParameterServices: false))
}

/// The names and hashes the node hands the transport session, on every distribution.
final class NodeTypeInfoDistroTests: XCTestCase {
    func testPublisherUsesHashForContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            _ = try await node.createPublisher(Plan.self, topic: "plan")

            let pub = try XCTUnwrap(mock.publishers.last, "\(distro)")
            // DDS and RCL name the type from this name alone; it is the same everywhere.
            XCTAssertEqual(pub.typeName, "distro_test_msgs/msg/Plan", "\(distro)")
            XCTAssertEqual(
                pub.typeHash,
                DistroFixture.pick(distro, jazzy: DistroFixture.planJazzy, lyrical: DistroFixture.planLyrical),
                "\(distro)")
            await ctx.shutdown()
        }
    }

    func testSubscriptionUsesHashForContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            _ = try await node.createSubscription(Plan.self, topic: "plan")

            let sub = try XCTUnwrap(mock.subscribers.last, "\(distro)")
            XCTAssertEqual(sub.typeName, "distro_test_msgs/msg/Plan", "\(distro)")
            XCTAssertEqual(
                sub.typeHash,
                DistroFixture.pick(distro, jazzy: DistroFixture.planJazzy, lyrical: DistroFixture.planLyrical),
                "\(distro)")
            await ctx.shutdown()
        }
    }

    func testServiceUsesHashesForContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            mock.installEchoServiceTransport()
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            _ = try await node.createService(ExecutePlanSrv.self, name: "execute") { _ in
                ExecutePlanSrv.Response(ok: true)
            }
            _ = try await node.createClient(ExecutePlanSrv.self, name: "execute")

            let request = DistroFixture.pick(
                distro, jazzy: DistroFixture.requestJazzy, lyrical: DistroFixture.requestLyrical)
            let response = distro.supportsTypeHash ? DistroFixture.response : nil
            for isServer in [true, false] {
                XCTAssertEqual(
                    mock.serviceEndpoints.filter { $0.isServer == isServer },
                    [
                        MockServiceEndpoint(
                            isServer: isServer, serviceTypeName: "distro_test_msgs/srv/ExecutePlan",
                            requestTypeHash: request, responseTypeHash: response)
                    ],
                    "\(distro) server: \(isServer)")
            }
            await ctx.shutdown()
        }
    }

    func testActionClientUsesActionHashesForContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let seen = Box<(String, ActionRoleTypeHashes)?>(nil)
            mock.actionClientFactory = { _, typeName, hashes, _ in
                seen.value = (typeName, hashes)
                return MockActionClient.makeAccepting()
            }
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            _ = try await node.createActionClient(FollowPlanAction.self, name: "follow")

            let (typeName, hashes) = try XCTUnwrap(seen.value, "\(distro)")
            XCTAssertEqual(typeName, "distro_test_msgs/action/FollowPlan", "\(distro)")
            assertActionHashes(hashes, distro)
            await ctx.shutdown()
        }
    }

    func testActionServerUsesActionHashesForContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let seen = Box<(String, ActionRoleTypeHashes)?>(nil)
            mock.actionServerFactory = { _, typeName, hashes, _, _ in
                seen.value = (typeName, hashes)
                return MockActionServer()
            }
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            _ = try await node.createActionServer(
                FollowPlanAction.self, name: "follow", handler: RecordingFollowPlanHandler(goals: Box([])))

            let (typeName, hashes) = try XCTUnwrap(seen.value, "\(distro)")
            XCTAssertEqual(typeName, "distro_test_msgs/action/FollowPlan", "\(distro)")
            assertActionHashes(hashes, distro)
            await ctx.shutdown()
        }
    }

    private func assertActionHashes(
        _ hashes: ActionRoleTypeHashes, _ distro: ROS2Distro, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            hashes.sendGoalRequest,
            DistroFixture.pick(
                distro, jazzy: DistroFixture.sendGoalRequestJazzy, lyrical: DistroFixture.sendGoalRequestLyrical),
            "\(distro)", file: file, line: line)
        XCTAssertEqual(
            hashes.sendGoalService,
            DistroFixture.pick(
                distro, jazzy: DistroFixture.sendGoalServiceJazzy, lyrical: DistroFixture.sendGoalServiceLyrical),
            "\(distro)", file: file, line: line)
        // The roles that do not reach the goal have one hash on every distribution with hashes.
        let shared = { (hash: String) in distro.supportsTypeHash ? hash : nil }
        XCTAssertEqual(
            hashes.getResultService, shared(DistroFixture.getResultService), "\(distro)", file: file, line: line)
        XCTAssertEqual(
            hashes.feedbackMessage, shared(DistroFixture.feedbackMessage), "\(distro)", file: file, line: line)
        XCTAssertEqual(
            hashes.statusArray, distro.supportsTypeHash ? GoalStatusArray.typeInfo.typeHash : nil, "\(distro)",
            file: file, line: line)
    }
}

/// The bytes publishers, subscriptions, services and action servers write and read.
final class PublisherSchemaDistroTests: XCTestCase {
    func testEncodesSchemaOfContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            let publisher = try await node.createPublisher(Plan.self, topic: "plan")
            try publisher.publish(DistroFixture.plan)

            let sent = try XCTUnwrap(mock.publishers.last?.publishedPayloads.last, "\(distro)")
            XCTAssertEqual(Array(sent.data), DistroFixture.planBytes(distro), "\(distro)")
            await ctx.shutdown()
        }
    }

    func testSubscriptionDecodesSchemaOfContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            let received = Box<[Plan]>([])
            _ = try await node.createSubscription(Plan.self, topic: "plan", qos: .sensorData, delivery: .stream) {
                plan in received.mutate { $0.append(plan) }
            }
            let sub = try XCTUnwrap(mock.subscribers.last, "\(distro)")
            sub.handler(Data(DistroFixture.planBytes(distro)), 0)

            await waitUntil("\(distro): a Plan arrives") { !received.value.isEmpty }
            XCTAssertEqual(received.value, [DistroFixture.decodedPlan(distro)], "\(distro)")
            await ctx.shutdown()
        }
    }

    func testServiceEncodesAndDecodesSchemaOfContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            mock.installEchoServiceTransport()
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            let requests = Box<[ExecutePlanRequest]>([])
            _ = try await node.createService(ExecutePlanSrv.self, name: "execute") { request in
                requests.mutate { $0.append(request) }
                return ExecutePlanSrv.Response(ok: true)
            }
            let client = try await node.createClient(ExecutePlanSrv.self, name: "execute")
            let response = try await client.call(ExecutePlanRequest(plan: DistroFixture.plan), timeout: .seconds(5))

            XCTAssertTrue(response.ok, "\(distro)")
            // The client writes the distribution's shape and the server reads the same shape, so
            // the value survives where the distribution has the field.
            XCTAssertEqual(requests.value.map(\.plan), [DistroFixture.decodedPlan(distro)], "\(distro)")
            await ctx.shutdown()
        }
    }

    func testActionServerDecodesGoalOfContextDistro() async throws {
        for distro in ROS2Distro.allCases {
            let mock = MockTransportSession()
            let handlers = Box<TransportActionServerHandlers?>(nil)
            mock.actionServerFactory = { _, _, _, _, bag in
                handlers.value = bag
                return MockActionServer()
            }
            let ctx = try await makeContext(distro, session: mock)
            let node = try await makeNode(ctx)
            let goals = Box<[FollowPlanAction.Goal]>([])
            _ = try await node.createActionServer(
                FollowPlanAction.self, name: "follow", handler: RecordingFollowPlanHandler(goals: goals))

            let onSendGoal = try XCTUnwrap(handlers.value?.onSendGoal, "\(distro)")
            _ = try await onSendGoal([UInt8](repeating: 7, count: 16), Data(DistroFixture.planBytes(distro)))
            XCTAssertEqual(goals.value.map(\.plan), [DistroFixture.decodedPlan(distro)], "\(distro)")
            await ctx.shutdown()
        }
    }
}

/// What a real Zenoh transport session puts on the wire for each distribution: the hash in the
/// key expressions and liveliness tokens, and the payload bytes.
final class ZenohDistroWireTests: XCTestCase {
    private static let distros: [ROS2Distro] = [.jazzy, .lyrical]

    private func makeZenohContext(_ distro: ROS2Distro) async throws -> (ROS2Context, RecordingZenohClient) {
        let client = RecordingZenohClient()
        let ctx = try await makeContext(distro, session: ZenohTransportSession(client: client))
        return (ctx, client)
    }

    func testPublisherKeyExpressionTokenAndBytesFollowContextDistro() async throws {
        for distro in Self.distros {
            let (ctx, zenoh) = try await makeZenohContext(distro)
            let node = try await makeNode(ctx)
            let publisher = try await node.createPublisher(Plan.self, topic: "plan")
            try publisher.publish(DistroFixture.plan)

            let hash = try XCTUnwrap(
                DistroFixture.pick(distro, jazzy: DistroFixture.planJazzy, lyrical: DistroFixture.planLyrical))
            let entity = "/distro_test_msgs::msg::dds_::Plan_/\(hash)"
            XCTAssertEqual(zenoh.publisherKeyExprs, ["0/plan/distro_test_msgs::msg::dds_::Plan_/\(hash)"], "\(distro)")
            XCTAssertEqual(
                zenoh.livelinessTokens.filter { $0.contains("/MP/") && $0.contains(entity + "/") }.count, 1,
                "\(distro): \(zenoh.livelinessTokens)")
            XCTAssertEqual(zenoh.puts.map { Array($0.payload) }, [DistroFixture.planBytes(distro)], "\(distro)")
            await ctx.shutdown()
        }
    }

    func testSubscriptionKeyExpressionAndDecodingFollowContextDistro() async throws {
        for distro in Self.distros {
            let (ctx, zenoh) = try await makeZenohContext(distro)
            let node = try await makeNode(ctx)
            let received = Box<[Plan]>([])
            _ = try await node.createSubscription(Plan.self, topic: "plan", qos: .sensorData, delivery: .stream) {
                plan in received.mutate { $0.append(plan) }
            }

            let hash = try XCTUnwrap(
                DistroFixture.pick(distro, jazzy: DistroFixture.planJazzy, lyrical: DistroFixture.planLyrical))
            let key = "0/plan/distro_test_msgs::msg::dds_::Plan_/\(hash)"
            XCTAssertTrue(zenoh.subscriptionKeyExprs.contains(key), "\(distro): \(zenoh.subscriptionKeyExprs)")
            let entity = "/distro_test_msgs::msg::dds_::Plan_/\(hash)/"
            XCTAssertEqual(
                zenoh.livelinessTokens.filter { $0.contains("/MS/") && $0.contains(entity) }.count, 1,
                "\(distro): \(zenoh.livelinessTokens)")

            zenoh.deliverSample(toKeyExpr: key, payload: Data(DistroFixture.planBytes(distro)))
            await waitUntil("\(distro): a Plan arrives") { !received.value.isEmpty }
            XCTAssertEqual(received.value, [DistroFixture.decodedPlan(distro)], "\(distro)")
            await ctx.shutdown()
        }
    }

    func testServiceKeyExpressionsAndBytesFollowContextDistro() async throws {
        let okResponse: [UInt8] = DistroFixture.header + [0x01]
        for distro in Self.distros {
            let (ctx, zenoh) = try await makeZenohContext(distro)
            let node = try await makeNode(ctx)
            let requests = Box<[ExecutePlanRequest]>([])
            _ = try await node.createService(ExecutePlanSrv.self, name: "execute") { request in
                requests.mutate { $0.append(request) }
                return ExecutePlanSrv.Response(ok: true)
            }
            let client = try await node.createClient(ExecutePlanSrv.self, name: "execute")

            let hash = try XCTUnwrap(
                DistroFixture.pick(
                    distro, jazzy: DistroFixture.serviceJazzy, lyrical: DistroFixture.serviceLyrical))
            let key = "0/execute/distro_test_msgs::srv::dds_::ExecutePlan_/\(hash)"
            XCTAssertEqual(zenoh.queryableKeyExprs, [key], "\(distro)")
            for kind in ["/SS/", "/SC/"] {
                XCTAssertEqual(
                    zenoh.livelinessTokens.filter {
                        $0.contains(kind) && $0.contains("/distro_test_msgs::srv::dds_::ExecutePlan_/\(hash)/")
                    }.count, 1, "\(distro) \(kind): \(zenoh.livelinessTokens)")
            }

            // Server: decodes the distribution's request shape and replies.
            let reply = try await zenoh.deliverQuery(
                toKeyExprWithPrefix: key, payload: Data(DistroFixture.planBytes(distro)))
            XCTAssertEqual(reply.map(Array.init), okResponse, "\(distro)")
            XCTAssertEqual(requests.value.map(\.plan), [DistroFixture.decodedPlan(distro)], "\(distro)")

            // Client: sends the distribution's request shape on the same key.
            zenoh.getReply = { _, _ in Data(okResponse) }
            let response = try await client.call(ExecutePlanRequest(plan: DistroFixture.plan), timeout: .seconds(5))
            XCTAssertTrue(response.ok, "\(distro)")
            let get = try XCTUnwrap(zenoh.gets.last, "\(distro)")
            XCTAssertEqual(get.keyExpr, key, "\(distro)")
            XCTAssertEqual(get.payload.map(Array.init), DistroFixture.planBytes(distro), "\(distro)")
            await ctx.shutdown()
        }
    }

    func testActionKeyExpressionsAndGoalBytesFollowContextDistro() async throws {
        for distro in Self.distros {
            let (ctx, zenoh) = try await makeZenohContext(distro)
            let node = try await makeNode(ctx)
            let goals = Box<[FollowPlanAction.Goal]>([])
            _ = try await node.createActionServer(
                FollowPlanAction.self, name: "follow", handler: RecordingFollowPlanHandler(goals: goals))
            let client = try await node.createActionClient(FollowPlanAction.self, name: "follow")

            let sendGoalHash = try XCTUnwrap(
                DistroFixture.pick(
                    distro, jazzy: DistroFixture.sendGoalServiceJazzy, lyrical: DistroFixture.sendGoalServiceLyrical))
            let sendGoalKey =
                "0/follow/_action/send_goal/distro_test_msgs::action::dds_::FollowPlan_SendGoal_/\(sendGoalHash)"
            let getResultKey =
                "0/follow/_action/get_result/distro_test_msgs::action::dds_::FollowPlan_GetResult_/"
                + DistroFixture.getResultService
            XCTAssertTrue(zenoh.queryableKeyExprs.contains(sendGoalKey), "\(distro): \(zenoh.queryableKeyExprs)")
            XCTAssertTrue(zenoh.queryableKeyExprs.contains(getResultKey), "\(distro): \(zenoh.queryableKeyExprs)")
            for kind in ["/SS/", "/SC/"] {
                XCTAssertEqual(
                    zenoh.livelinessTokens.filter {
                        $0.contains(kind)
                            && $0.contains("/distro_test_msgs::action::dds_::FollowPlan_SendGoal_/\(sendGoalHash)/")
                    }.count, 1, "\(distro) \(kind): \(zenoh.livelinessTokens)")
            }

            // Server: decodes the goal of the distribution's SendGoal request.
            let goalId = [UInt8](repeating: 7, count: 16)
            let request = DistroFixture.header + goalId + DistroFixture.planBody(distro)
            let reply = try await zenoh.deliverQuery(toKeyExprWithPrefix: sendGoalKey, payload: Data(request))
            XCTAssertEqual(reply?.prefix(5).map { $0 }, DistroFixture.header + [0x00], "\(distro): rejected")
            XCTAssertEqual(goals.value.map(\.plan), [DistroFixture.decodedPlan(distro)], "\(distro)")

            // Client: sends the goal in the distribution's shape on the same key.
            zenoh.getReply = { _, _ in
                ActionFrameDecoder.encodeSendGoalResponse(accepted: false, stampSec: 0, stampNanosec: 0)
            }
            do {
                _ = try await client.sendGoal(FollowPlanAction.Goal(plan: DistroFixture.plan))
                XCTFail("\(distro): the scripted reply rejects the goal")
            } catch ActionError.goalRejected {
                // expected
            }
            let get = try XCTUnwrap(zenoh.gets.last, "\(distro)")
            XCTAssertEqual(get.keyExpr, sendGoalKey, "\(distro)")
            let sent = try XCTUnwrap(get.payload, "\(distro)")
            XCTAssertEqual(Array(sent.prefix(4)), DistroFixture.header, "\(distro)")
            XCTAssertEqual(Array(sent.dropFirst(4 + 16)), DistroFixture.planBody(distro), "\(distro)")
            await ctx.shutdown()
        }
    }
}
