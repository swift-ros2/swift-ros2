import CDDSBridge
import Foundation
import XCTest

@testable import SwiftROS2DDS
@testable import SwiftROS2Transport

/// The bridge applies a domain's discovery config when it creates the domain.
/// It used to create each domain once per process, so a session opened after
/// the user changed the unicast peers or the network interface kept the old
/// config until the app was relaunched (youtalk/conduit#55). Once every
/// session of the domain is closed, the next session with a different config
/// now re-creates the domain; while sessions are open a different config fails.
///
/// Domains 84, 85, 86, 88, 89 and 90 are used by no other test (every test
/// target can run in one process), and at or below 101 their ports stay out of
/// the ephemeral range (see SessionCloseTests).
final class DomainReconfigureTests: XCTestCase {
    private func config(_ domain: Int, peer: String, nic: String = "") -> TransportConfig {
        TransportConfig(
            type: .dds, domainId: domain, ddsDiscoveryMode: .unicast,
            ddsUnicastPeers: [DDSPeer(address: peer, port: 7400)],
            ddsNetworkInterface: nic)
    }

    /// The XML the bridge applied to the domain it owns for `domain`, or "".
    private func appliedXML(_ domain: Int32) -> String {
        guard let xml = dds_bridge_copy_domain_config_xml(domain) else { return "" }
        defer { dds_bridge_free_string(xml) }
        return String(cString: xml)
    }

    private func creationFailure(_ error: Error) -> String? {
        guard let error = error as? DDSError, case .sessionCreationFailed(let message) = error else {
            return nil
        }
        return message
    }

    func testReconnectWithChangedPeersReappliesConfig() async throws {
        let a = DDSTransportSession(client: DDSClient())
        try await a.open(config: config(84, peer: "192.0.2.10"))
        try a.close()
        let b = DDSTransportSession(client: DDSClient())
        try await b.open(config: config(84, peer: "192.0.2.20"))
        defer { try? b.close() }
        let xml = appliedXML(84)
        XCTAssertTrue(xml.contains("192.0.2.20"), xml)
        XCTAssertFalse(xml.contains("192.0.2.10"), xml)
    }

    func testReconnectWithChangedInterfaceReappliesConfig() async throws {
        // The loopback interface, by the name CycloneDDS gives it (on Windows
        // the adapter's friendly name).
        #if os(Linux)
            let loopback = "lo"
        #elseif os(Windows)
            let loopback = "Loopback Pseudo-Interface 1"
        #else
            let loopback = "lo0"
        #endif
        let a = DDSTransportSession(client: DDSClient())
        try await a.open(config: config(85, peer: "192.0.2.10"))
        XCTAssertFalse(appliedXML(85).contains("NetworkInterface"))
        try a.close()
        let b = DDSTransportSession(client: DDSClient())
        try await b.open(config: config(85, peer: "192.0.2.10", nic: loopback))
        defer { try? b.close() }
        let xml = appliedXML(85)
        XCTAssertTrue(xml.contains("<NetworkInterface name=\"\(loopback)\"/>"), xml)
    }

    func testSameConfigSharesTheDomain() async throws {
        let a = DDSTransportSession(client: DDSClient())
        try await a.open(config: config(86, peer: "192.0.2.10"))
        defer { try? a.close() }
        let before = appliedXML(86)
        XCTAssertTrue(before.contains("192.0.2.10"), before)

        let b = DDSTransportSession(client: DDSClient())
        try await b.open(config: config(86, peer: "192.0.2.10"))
        defer { try? b.close() }
        XCTAssertTrue(a.isConnected)
        XCTAssertTrue(b.isConnected)
        XCTAssertEqual(appliedXML(86), before)
    }

    func testChangedConfigWhileSessionOpenFailsLoudly() async throws {
        let a = DDSTransportSession(client: DDSClient())
        try await a.open(config: config(86, peer: "192.0.2.10"))
        defer { try? a.close() }

        let b = DDSTransportSession(client: DDSClient())
        do {
            try await b.open(config: config(86, peer: "192.0.2.20"))
            try? b.close()
            XCTFail("expected a changed config to fail while another session of the domain is open")
        } catch {
            let message = try XCTUnwrap(creationFailure(error), "expected .sessionCreationFailed, got \(error)")
            XCTAssertTrue(message.contains("while"), message)
            XCTAssertTrue(message.contains("sessions"), message)
        }
        XCTAssertFalse(b.isConnected)
        XCTAssertTrue(a.isConnected)
        XCTAssertTrue(appliedXML(86).contains("192.0.2.10"))
    }

    /// The bridge keeps one domain record, of the latest session's domain. A
    /// session of another domain deletes the previous domain when none of its
    /// sessions is open, so coming back to it with a different config applies
    /// that config instead of finding the stale domain still there.
    func testSwitchingDomainsAndBackReappliesConfig() async throws {
        let a = DDSTransportSession(client: DDSClient())
        try await a.open(config: config(89, peer: "192.0.2.10"))
        try a.close()
        let b = DDSTransportSession(client: DDSClient())
        try await b.open(config: config(90, peer: "192.0.2.10"))
        try b.close()
        let c = DDSTransportSession(client: DDSClient())
        try await c.open(config: config(89, peer: "192.0.2.20"))
        defer { try? c.close() }
        let xml = appliedXML(89)
        XCTAssertTrue(xml.contains("192.0.2.20"), xml)
        XCTAssertFalse(xml.contains("192.0.2.10"), xml)
    }

    /// A domain created outside the bridge (by rmw or CRclBridge in the same
    /// process) is shared but never deleted, so its config cannot change.
    func testForeignDomainIsNeverDeleted() async throws {
        let handle = dds_bridge_test_create_raw_domain(88)
        XCTAssertGreaterThan(handle, 0)

        let a = DDSTransportSession(client: DDSClient())
        try await a.open(config: config(88, peer: "192.0.2.10"))
        XCTAssertTrue(a.isConnected)
        XCTAssertNil(dds_bridge_copy_domain_config_xml(88), "the bridge does not own domain 88")
        try a.close()

        let b = DDSTransportSession(client: DDSClient())
        do {
            try await b.open(config: config(88, peer: "192.0.2.20"))
            try? b.close()
            XCTFail("expected a changed config on a foreign domain to fail")
        } catch {
            let message = try XCTUnwrap(creationFailure(error), "expected .sessionCreationFailed, got \(error)")
            XCTAssertTrue(message.contains("owned by another component"), message)
        }
        XCTAssertEqual(dds_bridge_test_delete_raw_domain(handle), 0)
    }
}
