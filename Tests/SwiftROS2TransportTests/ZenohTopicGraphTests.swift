// ZenohTopicGraphTests.swift
// The wire Zenoh topic graph: the MP liveliness query, the session's own tokens, the
// deadline, single flight and the stalled-query budget.

import Foundation
import SwiftROS2TestSupport
import SwiftROS2Transport
import SwiftROS2Wire
import XCTest

final class ZenohTopicGraphTests: XCTestCase {
    private let remoteChatter =
        "@ros2_lv/0/aa11/0/10/MP/%/%/talker/%chatter/std_msgs::msg::dds_::String_/RIHS01_00/::,7:,:,:,,"
    private let remoteMap =
        "@ros2_lv/0/bb22/3/12/MP/%/%gt/map_server/%gt%map/nav_msgs::msg::dds_::OccupancyGrid_/:1:,1:,:,:,,"

    /// Short limits, so the stalled-query tests take about a second.
    private let shortLimits = ZenohGraphLimits(
        deadline: .milliseconds(150), abandonAfter: .milliseconds(500), stallCap: 3)

    private func openSession(
        _ client: MockZenohClient = MockZenohClient(), domainId: Int = 0
    ) async throws -> (ZenohTransportSession, MockZenohClient) {
        let session = ZenohTransportSession(client: client)
        try await session.open(
            config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: domainId, wireMode: .jazzy, connectionTimeout: 1))
        return (session, client)
    }

    private func publisher(
        _ session: ZenohTransportSession, topic: String = "/gt/chatter", qos: TransportQoS = .default
    ) throws -> any TransportPublisher {
        try session.createPublisher(
            topic: topic, typeName: "std_msgs/msg/String", typeHash: nil, qos: qos, nodeName: "pub_node",
            nodeNamespace: "/gt")
    }

    private func ownChatter(_ qos: (TransportQoS.Reliability, TransportQoS.Durability) = (.reliable, .volatile))
        -> GraphPublisherEndpoint
    {
        GraphPublisherEndpoint(
            topicName: "/gt/chatter", typeName: "std_msgs/msg/String", reliability: qos.0, durability: qos.1,
            nodeName: "pub_node", nodeNamespace: "/gt")
    }

    /// Asserts that `body` throws `.sessionUnhealthy` and returns how long it took.
    @discardableResult
    private func assertSessionUnhealthy(
        file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async -> Duration {
        let start = ContinuousClock.now
        do {
            try await body()
            XCTFail("expected sessionUnhealthy", file: file, line: line)
        } catch TransportError.sessionUnhealthy {
        } catch {
            XCTFail("expected sessionUnhealthy, got \(error)", file: file, line: line)
        }
        return ContinuousClock.now - start
    }

    // MARK: - Query and parsing

    func testQueriesTheMPTokensOfTheDomainAndParsesThem() async throws {
        let (session, client) = try await openSession(domainId: 7)
        defer { try? session.close() }
        client.remoteLivelinessTokens = [
            remoteChatter.replacingOccurrences(of: "@ros2_lv/0/", with: "@ros2_lv/7/"),
            remoteMap.replacingOccurrences(of: "@ros2_lv/0/", with: "@ros2_lv/7/"),
            // Not publishers, or not parseable: skipped.
            "@ros2_lv/7/cc/1/2/MS/%/%/n/%chatter/std_msgs::msg::dds_::String_/::,10:,:,:,,",
            "@ros2_lv/7/cc/1/2/MP/%/%/n/%chatter/std_msgs::msg::dds_::String_/garbage",
            // Another domain: not matched by the query.
            remoteChatter,
        ]

        let endpoints = try await session.publisherEndpoints()

        XCTAssertEqual(client.livelinessGets, ["@ros2_lv/7/*/*/*/MP/**"])
        XCTAssertEqual(
            Set(endpoints),
            [
                GraphPublisherEndpoint(
                    topicName: "/chatter", typeName: "std_msgs/msg/String", reliability: .reliable,
                    durability: .volatile, nodeName: "talker", nodeNamespace: "/"),
                GraphPublisherEndpoint(
                    topicName: "/gt/map", typeName: "nav_msgs/msg/OccupancyGrid", reliability: .reliable,
                    durability: .transientLocal, nodeName: "map_server", nodeNamespace: "/gt"),
            ])
        XCTAssertEqual(endpoints.count, 2)
    }

    func testThrowingGetMapsToSessionUnhealthy() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        // The mock fires onFinish before it throws, as the C bridge does: the call must
        // still fail rather than return an empty graph.
        client.livelinessGetShouldThrow = .internalError("boom")
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        client.livelinessGetShouldThrow = .sessionDisconnected("lost")
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertTrue(session.isConnected)
    }

    func testNotConnectedWhenTheClientIsUnhealthyOrTheSessionClosed() async throws {
        let (session, client) = try await openSession()
        client.healthOverride = false
        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected notConnected")
        } catch TransportError.notConnected {}
        client.healthOverride = nil
        try session.close()
        do {
            _ = try await session.publisherEndpoints()
            XCTFail("expected notConnected")
        } catch TransportError.notConnected {}
        XCTAssertTrue(client.livelinessGets.isEmpty)
    }

    func testConcurrentCallsMakeOneQuery() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        client.livelinessGetHolds = true

        async let first = session.publisherEndpoints()
        async let second = session.publisherEndpoints()
        await waitUntil { client.heldLivelinessQueries.count == 1 }
        // Give the second call time to arrive while the first query is in flight.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.livelinessGets.count, 1)

        let query = try XCTUnwrap(client.heldLivelinessQueries.first)
        query.reply(ZenohSample(keyExpr: remoteChatter, payload: Data(), attachment: nil))
        query.finish()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.map(\.topicName), ["/chatter"])
        XCTAssertEqual(b, a)
        XCTAssertEqual(client.livelinessGets.count, 1)
    }

    // MARK: - Own tokens

    func testOwnPublisherIsListedOnceWhetherOrNotTheRouterEchoesIt() async throws {
        for echoes in [true, false] {
            let client = MockZenohClient()
            client.livelinessEchoesOwnTokens = echoes
            let (session, _) = try await openSession(client)
            _ = try publisher(session)
            let endpoints = try await session.publisherEndpoints()
            XCTAssertEqual(endpoints, [ownChatter()], "echoes: \(echoes)")
            try session.close()
        }
    }

    func testClosedPublisherLeavesTheOwnTokenSet() async throws {
        let client = MockZenohClient()
        client.livelinessEchoesOwnTokens = false
        let (session, _) = try await openSession(client)
        defer { try? session.close() }
        let latched = try publisher(
            session, topic: "/gt/latched",
            qos: TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1)))
        let plain = try publisher(session)

        var endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints.map(\.topicName).sorted(), ["/gt/chatter", "/gt/latched"])
        XCTAssertEqual(endpoints.first { $0.topicName == "/gt/latched" }?.durability, .transientLocal)

        try latched.close()
        endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [ownChatter()])

        try plain.close()
        endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [])
        // The token itself was undeclared too.
        XCTAssertEqual(client.livelinessHandles.map(\.closeCount), [1, 1])
    }

    func testClosedActionServerTokensLeaveTheOwnTokenSet() async throws {
        let client = MockZenohClient()
        client.livelinessEchoesOwnTokens = false
        let (session, _) = try await openSession(client)
        defer { try? session.close() }
        let server = try session.createActionServer(
            name: "/fibonacci", actionTypeName: "example_interfaces/action/Fibonacci",
            roleTypeHashes: ActionRoleTypeHashes(
                sendGoalRequest: nil, sendGoalResponse: nil, cancelGoalRequest: nil, cancelGoalResponse: nil,
                getResultRequest: nil, getResultResponse: nil, feedbackMessage: nil, statusArray: nil),
            qos: .default,
            handlers: TransportActionServerHandlers(
                onSendGoal: { _, _ in (true, 0, 0) }, onCancelGoal: { _ in Data() },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }))

        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(
            endpoints.sorted { $0.topicName < $1.topicName }.map { "\($0.topicName) \($0.typeName) \($0.durability)" },
            [
                "/fibonacci/_action/feedback example_interfaces/action/Fibonacci_FeedbackMessage volatile",
                "/fibonacci/_action/status action_msgs/msg/GoalStatusArray transientLocal",
            ])

        try server.close()
        let after = try await session.publisherEndpoints()
        XCTAssertEqual(after, [])
    }

    /// Remote nodes do not see a publisher whose token failed, so neither does the graph.
    func testPublisherWhoseDeclarationFailedIsNotListed() async throws {
        let client = MockZenohClient()
        client.livelinessEchoesOwnTokens = false
        let (session, _) = try await openSession(client)
        defer { try? session.close() }
        client.declareLivelinessTokenShouldThrow = .internalError("boom")
        _ = try publisher(session)
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [])
    }

    func testOwnTokenSetIsEmptyAfterClose() async throws {
        let client = MockZenohClient()
        client.livelinessEchoesOwnTokens = false
        let (session, _) = try await openSession(client)
        _ = try publisher(session)
        try session.close()
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0, connectionTimeout: 1))
        defer { try? session.close() }
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [])
    }

    /// A publisher token declared while the session closes is not listed after a reopen.
    func testTokenDeclaredWhileClosingIsNotListedAfterReopen() async throws {
        let client = MockZenohClient()
        client.livelinessEchoesOwnTokens = false
        let (session, _) = try await openSession(client)
        // close() runs between the declaration and the token joining the own-token set.
        client.onDeclareLivelinessToken = { keyExpr in
            guard keyExpr.contains("/MP/") else { return }
            client.onDeclareLivelinessToken = nil
            try? session.close()
        }
        _ = try? publisher(session)
        XCTAssertNil(client.onDeclareLivelinessToken, "the publisher token was never declared")

        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0, connectionTimeout: 1))
        defer { try? session.close() }
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [])
    }

    // MARK: - Deadline, single flight, stalled budget

    func testUnansweredQueryThrowsAtTheDeadlineAndALateFinalIsHarmless() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        session.graphLimits = shortLimits
        client.livelinessGetHolds = true

        let elapsed = await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150))
        XCTAssertLessThan(elapsed, .seconds(1))

        // A reply and the final after the deadline: no second resume, nothing returned.
        let query = try XCTUnwrap(client.heldLivelinessQueries.first)
        query.reply(ZenohSample(keyExpr: remoteChatter, payload: Data(), attachment: nil))
        query.finish()
        query.finish()

        // The query has its final, so the next call starts a new one.
        client.livelinessGetHolds = false
        client.remoteLivelinessTokens = [remoteChatter]
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints.map(\.topicName), ["/chatter"])
        XCTAssertEqual(client.livelinessGets.count, 2)
    }

    func testCallWhileATimedOutQueryIsPendingThrowsAtOnceThenANewQueryStartsAfterTheAbandonTime() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        session.graphLimits = shortLimits
        client.livelinessGetHolds = true

        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        // The query started before the first call returned, so `abandonAfter` after that
        // return it is old enough to abandon, however slow the runner is.
        let firstReturned = ContinuousClock.now

        let atOnce = await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertLessThan(atOnce, .milliseconds(100))
        XCTAssertEqual(client.livelinessGets.count, 1)

        try await Task.sleep(until: firstReturned + shortLimits.abandonAfter, clock: .continuous)
        client.livelinessGetHolds = false
        client.remoteLivelinessTokens = [remoteChatter]
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints.map(\.topicName), ["/chatter"])
        XCTAssertEqual(client.livelinessGets.count, 2)
        XCTAssertTrue(session.isConnected)
    }

    func testLateFinalOfAnAbandonedQueryLowersTheCount() async throws {
        let (session, client) = try await openSession()
        defer { try? session.close() }
        session.graphLimits = ZenohGraphLimits(
            deadline: .milliseconds(150), abandonAfter: .milliseconds(400), stallCap: 2)
        client.livelinessGetHolds = true

        // q1 times out and is abandoned by the call that starts q2.
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        try await Task.sleep(for: .milliseconds(450))
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertEqual(client.livelinessGets.count, 2)

        // q1's final arrives: one abandoned query fewer.
        client.heldLivelinessQueries[0].finish()

        // Abandoning q2 now leaves one abandoned query, below the cap of 2: q3 starts.
        try await Task.sleep(for: .milliseconds(450))
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertEqual(client.livelinessGets.count, 3)
        XCTAssertTrue(session.isConnected)
    }

    func testThirdAbandonedQueryMarksTheSessionGraphStalled() async throws {
        let (session, client) = try await openSession()
        session.graphLimits = shortLimits
        let pub = try publisher(session)
        client.livelinessGetHolds = true

        // q1, q2 and q3 each time out; each later call abandons the one before.
        for expectedGets in 1...3 {
            await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
            XCTAssertEqual(client.livelinessGets.count, expectedGets)
            XCTAssertTrue(session.isConnected)
            try await Task.sleep(for: .milliseconds(550))
        }

        // Abandoning q3 reaches the cap: the call throws at once and starts nothing.
        let atOnce = await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertLessThan(atOnce, .milliseconds(100))
        XCTAssertEqual(client.livelinessGets.count, 3)
        XCTAssertFalse(session.isConnected)

        // Sticky: later calls throw at once, and late finals do not clear the mark.
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        for query in client.heldLivelinessQueries { query.finish() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(session.isConnected)
        await assertSessionUnhealthy { _ = try await session.publisherEndpoints() }
        XCTAssertEqual(client.livelinessGets.count, 3)

        // Publishing and creating entities keep working on a graph-stalled session.
        try pub.publish(data: Data([0, 1, 0, 0]), timestamp: 1, sequenceNumber: 1)
        XCTAssertEqual(client.puts.count, 1)
        XCTAssertNoThrow(try publisher(session, topic: "/gt/other"))

        // close() resets the mark.
        try session.close()
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 0, connectionTimeout: 1))
        defer { try? session.close() }
        XCTAssertTrue(session.isConnected)
        client.livelinessGetHolds = false
        let endpoints = try await session.publisherEndpoints()
        XCTAssertEqual(endpoints, [])
    }

    /// Closing the session fails a call that is waiting with `.notConnected`.
    func testCloseFailsAWaitingCall() async throws {
        let (session, client) = try await openSession()
        client.livelinessGetHolds = true
        async let call = session.publisherEndpoints()
        await waitUntil { client.heldLivelinessQueries.count == 1 }
        try session.close()
        do {
            _ = try await call
            XCTFail("expected notConnected")
        } catch TransportError.notConnected {}
    }
}
