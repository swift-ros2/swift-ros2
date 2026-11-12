import SwiftROS2
import SwiftROS2Transport
import XCTest

final class ContextFactoryTests: XCTestCase {
    /// Verifies that ROS2Context can build a default Zenoh session without
    /// the caller having to construct a transport. The connection itself
    /// will fail because no router is running at the dummy locator, but the
    /// factory path must NOT throw `unsupportedFeature`.
    func testZenohContextBuildsDefaultSession() async {
        let config = TransportConfig(
            type: .zenoh,
            zenohLocator: "tcp/127.0.0.1:17447",  // bogus port, nothing listens
            connectionTimeout: 1.0
        )

        do {
            let ctx = try await ROS2Context(transport: config)
            _ = ctx
            XCTFail("Expected connection to fail (no router), but succeeded")
        } catch TransportError.unsupportedFeature(let msg) {
            XCTFail("Factory should build a default session, but hit unsupportedFeature: \(msg)")
        } catch {
            // Any other error is acceptable — connectionFailed is typical.
        }
    }

    #if SWIFT_ROS2_HAS_DDS
        /// Same shape for DDS. DDS requires a live discovery environment; on
        /// macOS (no multicast) we just verify the factory wires a DDSTransportSession
        /// rather than throwing unsupportedFeature.
        func testDDSContextBuildsDefaultSession() async {
            let config = TransportConfig(
                type: .dds,
                domainId: 99  // unused domain
            )

            do {
                let ctx = try await ROS2Context(transport: config)
                _ = ctx
            } catch TransportError.unsupportedFeature(let msg) {
                XCTFail("Factory should build a default session, but hit unsupportedFeature: \(msg)")
            } catch {
                // connectionFailed or similar is acceptable.
            }
        }
    #else
        func testDDSContextFailsLoudlyWithoutCycloneDDS() async {
            do {
                _ = try await ROS2Context(transport: .ddsMulticast(domainId: 0))
                XCTFail("expected unsupportedFeature")
            } catch TransportError.unsupportedFeature {
                // expected
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    #endif
}
