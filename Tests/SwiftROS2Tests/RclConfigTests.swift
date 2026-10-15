import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Transport

final class RclConfigTests: XCTestCase {
    func testRclFactoryProducesRclConfig() throws {
        let cfg = TransportConfig.rcl(domainId: 7)
        XCTAssertEqual(cfg.type, .rcl)
        XCTAssertEqual(cfg.domainId, 7)
        XCTAssertNil(cfg.zenohLocator)
        XCTAssertNil(cfg.wireMode)
        XCTAssertEqual(cfg.ddsDiscoveryMode, .multicast)
        XCTAssertTrue(cfg.ddsUnicastPeers.isEmpty)
        XCTAssertNoThrow(try cfg.validate())
    }

    func testRclContextThrowsWhenBackendNotBuilt() async throws {
        #if SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend is built; throw-path not applicable")
        #else
            do {
                _ = try await ROS2Context(transport: .rcl(domainId: 0))
                XCTFail("expected unsupportedFeature")
            } catch let error as TransportError {
                guard case .unsupportedFeature = error else {
                    return XCTFail("expected unsupportedFeature, got \(error)")
                }
            } catch {
                XCTFail("expected TransportError, got \(error)")
            }
        #endif
    }
}
