import SwiftROS2Transport
import XCTest

final class TransportConfigTests: XCTestCase {
    // MARK: - TransportType

    func testTransportTypeDisplayNames() {
        XCTAssertEqual(TransportType.zenoh.displayName, "Zenoh")
        XCTAssertEqual(TransportType.dds.displayName, "DDS")
    }

    func testTransportTypeRoundTripsThroughCodable() throws {
        for type in TransportType.allCases {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(TransportType.self, from: data)
            XCTAssertEqual(type, decoded)
        }
    }

    // MARK: - DDSDiscoveryMode

    func testDDSDiscoveryModePeerRequirement() {
        XCTAssertFalse(DDSDiscoveryMode.multicast.requiresPeerConfiguration)
        XCTAssertTrue(DDSDiscoveryMode.unicast.requiresPeerConfiguration)
        XCTAssertTrue(DDSDiscoveryMode.hybrid.requiresPeerConfiguration)
    }

    // MARK: - DDSPeer

    func testDDSPeerLocatorString() {
        let peer = DDSPeer(address: "192.168.1.10", port: 7400)
        XCTAssertEqual(peer.locator, "udp/192.168.1.10:7400")
    }

    // The `<Peer address="..."/>` form CycloneDDS consumes MUST carry the port.
    // Without one, add_addresses_to_addrset_1() patches in the *participant*
    // unicast discovery port (7400 + 250*domain + 10) and then probes indices
    // 1...MaxAutoParticipantIndex (7412, 7414, ... 7426 on domain 0) — ports
    // nothing listens on when the remote runs the default ParticipantIndex
    // ("none", so its unicast ports are ephemeral). Issue #176.
    func testDDSPeerDiscoveryAddressCarriesPort() {
        XCTAssertEqual(DDSPeer(address: "192.168.1.10", port: 7400).discoveryAddress, "192.168.1.10:7400")
        XCTAssertEqual(DDSPeer.peer(address: "10.0.0.1", domainId: 1).discoveryAddress, "10.0.0.1:7650")
    }

    // A bare IPv6 address must be bracketed or CycloneDDS reads the trailing
    // ":7400" as part of the address (ddsi_ipaddr_from_string only honors a
    // port when the address is bracketed), silently targeting a different host.
    func testDDSPeerDiscoveryAddressBracketsIPv6() {
        XCTAssertEqual(DDSPeer(address: "fe80::1", port: 7400).discoveryAddress, "[fe80::1]:7400")
        XCTAssertEqual(DDSPeer(address: "[fe80::1]", port: 7400).discoveryAddress, "[fe80::1]:7400")
    }

    // Every participant of a Linux host binds the shared discovery port with
    // address reuse, and the kernel delivers a unicast datagram there to the
    // newest socket only (youtalk/conduit#123). The bare host makes CycloneDDS
    // also probe each participant index's own unicast port; the host:port entry
    // keeps reaching participants without an index (#176).
    func testDDSPeerDiscoveryAddressesListHostPortThenBareHost() {
        XCTAssertEqual(
            DDSPeer.peer(address: "192.168.1.238", domainId: 123).discoveryAddresses,
            ["192.168.1.238:38150", "192.168.1.238"])
        XCTAssertEqual(DDSPeer(address: "fe80::1", port: 7400).discoveryAddresses, ["[fe80::1]:7400", "fe80::1"])
        XCTAssertEqual(DDSPeer(address: "[fe80::1]", port: 7400).discoveryAddresses, ["[fe80::1]:7400", "fe80::1"])
    }

    func testDDSPeerDiscoveryPortFormula() {
        XCTAssertEqual(DDSPeer.discoveryPort(forDomain: 0), 7400)
        XCTAssertEqual(DDSPeer.discoveryPort(forDomain: 1), 7650)
        XCTAssertEqual(DDSPeer.discoveryPort(forDomain: 42), 17900)
    }

    func testDDSPeerFactoryAppliesDiscoveryPort() {
        let peer = DDSPeer.peer(address: "10.0.0.1", domainId: 1)
        XCTAssertEqual(peer.address, "10.0.0.1")
        XCTAssertEqual(peer.port, 7650)
    }

    // MARK: - TransportConfig.zenoh factory

    func testZenohFactoryDefaults() throws {
        let config = TransportConfig.zenoh(locator: "tcp/localhost:7447")
        XCTAssertEqual(config.type, .zenoh)
        XCTAssertEqual(config.domainId, 0)
        XCTAssertEqual(config.zenohLocator, "tcp/localhost:7447")
        XCTAssertNil(config.wireMode)
        XCTAssertEqual(config.connectionTimeout, 10.0)
        XCTAssertNoThrow(try config.validate())
    }

    // MARK: - TransportConfig.ddsMulticast factory

    func testDDSMulticastFactoryValidates() throws {
        let config = TransportConfig.ddsMulticast(domainId: 5)
        XCTAssertEqual(config.type, .dds)
        XCTAssertEqual(config.domainId, 5)
        XCTAssertEqual(config.ddsDiscoveryMode, .multicast)
        XCTAssertNoThrow(try config.validate())
    }

    func testDDSUnicastFactoryRequiresPeers() throws {
        let goodConfig = TransportConfig.ddsUnicast(
            peers: [DDSPeer(address: "10.0.0.1")],
            domainId: 0
        )
        XCTAssertNoThrow(try goodConfig.validate())

        let badConfig = TransportConfig.ddsUnicast(peers: [], domainId: 0)
        XCTAssertThrowsError(try badConfig.validate()) { error in
            guard case TransportError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration, got \(error)")
                return
            }
        }
    }

    func testRclUnicastFactoryAndValidate() throws {
        let peer = DDSPeer(address: "192.168.1.85", port: DDSPeer.discoveryPort(forDomain: 0))
        let cfg = TransportConfig.rclUnicast(peers: [peer], domainId: 0, interface: "en0")
        XCTAssertEqual(cfg.type, .rcl)
        XCTAssertEqual(cfg.ddsDiscoveryMode, .unicast)
        XCTAssertEqual(cfg.ddsUnicastPeers, [peer])
        XCTAssertEqual(cfg.ddsNetworkInterface, "en0")
        XCTAssertNoThrow(try cfg.validate())
        let bad = TransportConfig.rclUnicast(peers: [], domainId: 0, interface: nil)
        XCTAssertThrowsError(try bad.validate())
    }

    /// Interface-only (no static peers) is a valid RCL discovery config — pin
    /// the NIC, keep multicast SPDP — and must pass validate(); applyDiscoveryEnv
    /// honours it (its guard is `!peers.isEmpty || interface != nil`).
    func testRclUnicastInterfaceOnlyIsValid() throws {
        let cfg = TransportConfig.rclUnicast(peers: [], domainId: 0, interface: "en0")
        XCTAssertEqual(cfg.type, .rcl)
        XCTAssertEqual(cfg.ddsDiscoveryMode, .multicast)
        XCTAssertTrue(cfg.ddsUnicastPeers.isEmpty)
        XCTAssertEqual(cfg.ddsNetworkInterface, "en0")
        XCTAssertNoThrow(try cfg.validate())
    }

    // MARK: - validate()

    func testValidateRejectsNegativeDomainId() {
        let config = TransportConfig(type: .zenoh, domainId: -1, zenohLocator: "tcp/x:7447")
        XCTAssertThrowsError(try config.validate())
    }

    func testValidateRejectsTooLargeDomainId() {
        let config = TransportConfig(type: .zenoh, domainId: 233, zenohLocator: "tcp/x:7447")
        XCTAssertThrowsError(try config.validate())
    }

    func testValidateAcceptsBoundaryDomainIds() throws {
        let lo = TransportConfig(type: .zenoh, domainId: 0, zenohLocator: "tcp/x:7447")
        let hi = TransportConfig(type: .zenoh, domainId: 232, zenohLocator: "tcp/x:7447")
        XCTAssertNoThrow(try lo.validate())
        XCTAssertNoThrow(try hi.validate())
    }

    func testValidateRejectsZenohWithoutLocator() {
        let config = TransportConfig(type: .zenoh, zenohLocator: nil)
        XCTAssertThrowsError(try config.validate())
    }

    func testValidateRejectsZenohWithEmptyLocator() {
        let config = TransportConfig(type: .zenoh, zenohLocator: "")
        XCTAssertThrowsError(try config.validate())
    }
}
