import XCTest

@testable import SwiftROS2DDS
@testable import SwiftROS2Transport

/// `dds_bridge_create_session` used to ignore a failed `dds_create_domain` and
/// carry on to `dds_create_participant`, which then created an *implicit*
/// domain on the DEFAULT configuration — no `<Peers>`, multicast SPDP — while
/// reporting the session as connected. A rejected discovery config therefore
/// looked exactly like a firewall block: nothing discovered, nothing logged.
/// That silent degradation is the same failure class as issue #176, so the
/// bridge now surfaces the rejection.
final class DiscoveryConfigFailLoudTests: XCTestCase {
    func testUnusableDiscoveryConfigSurfacesAsError() async throws {
        let session = DDSTransportSession(client: DDSClient())
        // An interface name no NIC can have: CycloneDDS rejects the config at
        // domain creation. The bridge applies a config only when it creates the
        // domain, so this test needs a domain no other test in the package uses:
        // `swift test --build-system native` and Xcode run every test target in
        // one process, and a domain another test created first (42 belongs to
        // DDSRoundTripTests) would take the session without the config. 83 is
        // used nowhere else, and at or below 101 its ports stay out of the
        // ephemeral range (see SessionCloseTests).
        let config = TransportConfig(
            type: .dds, domainId: 83, ddsDiscoveryMode: .unicast,
            ddsUnicastPeers: [DDSPeer(address: "192.0.2.10", port: 7400)],
            ddsNetworkInterface: "definitely-not-a-nic0")
        do {
            try await session.open(config: config)
            try? session.close()
            XCTFail("expected a rejected discovery config to throw, not to fall back to defaults")
        } catch let error as DDSError {
            guard case .sessionCreationFailed(let message) = error else {
                return XCTFail("expected .sessionCreationFailed, got \(error)")
            }
            XCTAssertTrue(
                message.contains("discovery configuration"),
                "expected the CycloneDDS rejection to be named in the error, got: \(message)")
        }
        XCTAssertFalse(session.isConnected)
    }
}
