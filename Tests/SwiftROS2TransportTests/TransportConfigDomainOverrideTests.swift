// TransportConfigDomainOverrideTests.swift
// `TransportConfig.withDomainId(_:)` — what `ROS2Context(transport:distro:domainId:)`
// opens the session with — and the domain each backend then runs on.

import SwiftROS2Wire
import XCTest

@testable import SwiftROS2Transport

final class TransportConfigDomainOverrideTests: XCTestCase {
    // MARK: - withDomainId

    func testZenohKeepsEveryFieldButTheDomain() {
        let base = TransportConfig.zenoh(
            locator: "tcp/192.168.1.238:7447", domainId: 0, wireMode: .lyrical, connectionTimeout: 3)
        let moved = base.withDomainId(123)
        XCTAssertEqual(moved.domainId, 123)
        XCTAssertEqual(moved.type, .zenoh)
        XCTAssertEqual(moved.zenohLocator, "tcp/192.168.1.238:7447")
        XCTAssertEqual(moved.wireMode, .lyrical)
        XCTAssertEqual(moved.connectionTimeout, 3)
    }

    func testUnicastPeersOnTheOldDiscoveryPortMoveToTheNewOne() {
        let base = TransportConfig.ddsUnicast(
            peers: [
                DDSPeer(address: "10.0.0.1"),  // default 7400 = domain 0's discovery port
                DDSPeer(address: "10.0.0.2", port: 9000),  // custom port: kept
            ],
            domainId: 0)
        let moved = base.withDomainId(123)
        XCTAssertEqual(moved.domainId, 123)
        XCTAssertEqual(moved.ddsDiscoveryMode, .unicast)
        XCTAssertEqual(
            moved.ddsUnicastPeers,
            [DDSPeer(address: "10.0.0.1", port: 38150), DDSPeer(address: "10.0.0.2", port: 9000)])
    }

    func testRclUnicastKeepsInterfaceAndMovesPeers() {
        let base = TransportConfig.rclUnicast(
            peers: [DDSPeer.peer(address: "10.0.0.1", domainId: 5)], domainId: 5, interface: "en0")
        let moved = base.withDomainId(7)
        XCTAssertEqual(moved.type, .rcl)
        XCTAssertEqual(moved.domainId, 7)
        XCTAssertEqual(moved.ddsNetworkInterface, "en0")
        XCTAssertEqual(moved.ddsUnicastPeers, [DDSPeer.peer(address: "10.0.0.1", domainId: 7)])
    }

    func testPeersAlreadyOnTheNewDomainsPortAreKept() {
        // A caller that already aimed the peer at domain 123's port while the
        // transport says domain 0 keeps that peer.
        let peer = DDSPeer.peer(address: "10.0.0.1", domainId: 123)
        let moved = TransportConfig.ddsUnicast(peers: [peer], domainId: 0).withDomainId(123)
        XCTAssertEqual(moved.ddsUnicastPeers, [peer])
    }

    func testSameDomainIsUnchanged() {
        let base = TransportConfig.ddsUnicast(peers: [DDSPeer(address: "10.0.0.1")], domainId: 0)
        let same = base.withDomainId(0)
        XCTAssertEqual(same.domainId, 0)
        XCTAssertEqual(same.ddsUnicastPeers, base.ddsUnicastPeers)
    }

    func testOutOfRangeDomainIsLeftForValidateToReject() {
        let moved = TransportConfig.ddsUnicast(peers: [DDSPeer(address: "10.0.0.1")], domainId: 0)
            .withDomainId(300)
        XCTAssertEqual(moved.domainId, 300)
        XCTAssertEqual(moved.ddsUnicastPeers, [DDSPeer(address: "10.0.0.1")])
        XCTAssertThrowsError(try moved.validate())
    }

    // MARK: - Backends follow the overridden domain

    func testZenohKeyExpressionsCarryTheOverriddenDomain() async throws {
        let client = MockZenohClient()
        let session = ZenohTransportSession(client: client)
        try await session.open(
            config: TransportConfig.zenoh(locator: "tcp/127.0.0.1:7447", wireMode: .jazzy, connectionTimeout: 1)
                .withDomainId(123))
        _ = try session.createPublisher(
            topic: "/e2e/imu", typeName: "sensor_msgs/msg/Imu", typeHash: "RIHS01_abc", qos: .sensorData)
        _ = try session.createSubscriber(
            topic: "/e2e/chatter", typeName: "std_msgs/msg/String", typeHash: "RIHS01_def", qos: .sensorData,
            handler: { _, _ in })

        XCTAssertEqual(client.publisherDeclarations, ["123/e2e/imu/sensor_msgs::msg::dds_::Imu_/RIHS01_abc"])
        XCTAssertEqual(client.subscriptions.count, 1)
        XCTAssertTrue(client.subscriptions.first?.key.hasPrefix("123/e2e/chatter/") == true)
        XCTAssertFalse(client.livelinessDeclarations.isEmpty)
        for token in client.livelinessDeclarations {
            XCTAssertTrue(token.hasPrefix("@ros2_lv/123/"), "liveliness token \(token) is not on domain 123")
        }
        try session.close()
    }

    func testDDSParticipantAndPeersFollowTheOverriddenDomain() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(
            config: TransportConfig.ddsUnicast(peers: [DDSPeer(address: "192.168.1.238")], domainId: 0)
                .withDomainId(123))
        XCTAssertEqual(client.sessionCreations.count, 1)
        XCTAssertEqual(client.sessionCreations.first?.domainId, 123)
        XCTAssertEqual(
            client.sessionCreations.first?.config.unicastPeers, ["192.168.1.238:38150", "192.168.1.238"])
        try session.close()
    }

    func testRclPeersAreListedWithTheirPortAndAsTheBareHost() async throws {
        let client = MockRclClient()
        let session = RclTransportSession(client: client)
        try await session.open(
            config: TransportConfig.rclUnicast(
                peers: [DDSPeer.peer(address: "192.168.1.238", domainId: 123)], domainId: 123))
        XCTAssertEqual(client.lastUnicastPeerAddresses, ["192.168.1.238:38150", "192.168.1.238"])
        try session.close()
    }

    func testRclContextFollowsTheOverriddenDomain() async throws {
        let client = MockRclClient()
        let session = RclTransportSession(client: client)
        try await session.open(config: TransportConfig.rcl(domainId: 0).withDomainId(123))
        XCTAssertEqual(client.lastDomainId, 123)
        XCTAssertEqual(session.sessionId, "rcl-123")
        try session.close()
    }
}
