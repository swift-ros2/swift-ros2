#if SWIFT_ROS2_RCL_RMW_ZENOH
    import Foundation
    import SwiftROS2RCL
    import XCTest

    /// Drift guard for the embedded rmw_zenoh default configs.
    ///
    /// Two independent copies of DEFAULT_RMW_ZENOH_{SESSION,ROUTER}_CONFIG
    /// .json5 exist: the runtime synthesis embeds them as Swift constants
    /// (`RmwZenohDefaultConfig`), and the xcframework build copies them from
    /// the RMW_ZENOH_PIN checkout (`assemble_zenoh_ament_prefix` in
    /// Scripts/build-ros2-xcframework.sh). A pin bump that re-vendors the
    /// checkout without re-copying the constants would silently diverge the
    /// runtime config from the built rmw — this test pins them together
    /// byte-for-byte. Outside CI it skips when the pinned checkout is not
    /// materialized; under GitHub Actions the ci-rcl zenoh leg always provides
    /// the two files (built, or fetched at the pin on a warm cache), so a
    /// missing file fails there instead of silently disabling the guard.
    final class RmwZenohConfigDriftTests: XCTestCase {
        private var pinnedConfigDir: URL {
            // Tests/SwiftROS2RCLTests/<file> → repo root → pinned checkout.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "build/ros2zenoh/src_ws/ros2/rmw_zenoh/rmw_zenoh_cpp/config",
                    isDirectory: true)
        }

        func testEmbeddedConfigsMatchPinnedCheckout() throws {
            let sessionURL = pinnedConfigDir.appendingPathComponent(
                "DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5")
            let routerURL = pinnedConfigDir.appendingPathComponent(
                "DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5")
            guard FileManager.default.fileExists(atPath: sessionURL.path) else {
                if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
                    XCTFail(
                        "pinned rmw_zenoh configs missing at \(pinnedConfigDir.path); "
                            + "the ci-rcl zenoh leg must provide them")
                    return
                }
                throw XCTSkip(
                    "pinned rmw_zenoh checkout not materialized — "
                        + "RMW_VARIANT=zenoh Scripts/build-ros2-xcframework.sh populates it")
            }
            XCTAssertEqual(
                RmwZenohDefaultConfig.sessionConfigJSON5,
                try String(contentsOf: sessionURL, encoding: .utf8),
                "embedded session config drifted from the pinned rmw_zenoh checkout — "
                    + "re-copy RmwZenohDefaultConfig.sessionConfigJSON5")
            XCTAssertEqual(
                RmwZenohDefaultConfig.routerConfigJSON5,
                try String(contentsOf: routerURL, encoding: .utf8),
                "embedded router config drifted from the pinned rmw_zenoh checkout — "
                    + "re-copy RmwZenohDefaultConfig.routerConfigJSON5")
        }
    }
#endif
