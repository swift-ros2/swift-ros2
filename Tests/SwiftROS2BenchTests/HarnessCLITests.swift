import SwiftROS2Bench
import XCTest

final class HarnessCLITests: XCTestCase {
    func testSupportedBackends() {
        XCTAssertTrue(HarnessCLI.supportedBackends.contains("rcl"))
        XCTAssertTrue(HarnessCLI.supportedBackends.contains("dds"))
        XCTAssertTrue(HarnessCLI.supportedBackends.contains("zenoh"))
        XCTAssertFalse(HarnessCLI.supportedBackends.contains("fastdds"))
    }

    func testLocatorFlagWinsOverEnvironment() {
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: ["rcl-bench", "zenoh", "publish", "--locator", "tcp/10.0.0.5:7447"],
            environment: [HarnessCLI.zenohLocatorEnvVar: "tcp/192.168.1.1:7447"])
        XCTAssertEqual(locator, "tcp/10.0.0.5:7447")
    }

    func testEnvironmentFallback() {
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: ["rcl-bench", "zenoh", "publish"],
            environment: [HarnessCLI.zenohLocatorEnvVar: "tcp/192.168.1.1:7447"])
        XCTAssertEqual(locator, "tcp/192.168.1.1:7447")
    }

    func testDefaultWhenNothingGiven() {
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: ["rcl-bench", "zenoh", "publish"], environment: [:])
        XCTAssertEqual(locator, HarnessCLI.defaultZenohLocator)
        XCTAssertEqual(locator, "tcp/127.0.0.1:7447")
    }

    func testTrailingLocatorFlagWithoutValueFallsThrough() {
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: ["rcl-bench", "zenoh", "publish", "--locator"],
            environment: [HarnessCLI.zenohLocatorEnvVar: "tcp/192.168.1.1:7447"])
        XCTAssertEqual(locator, "tcp/192.168.1.1:7447")
    }

    func testEmptyLocatorValueFallsThrough() {
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: ["rcl-bench", "zenoh", "publish", "--locator", ""],
            environment: [HarnessCLI.zenohLocatorEnvVar: "tcp/192.168.1.1:7447"])
        XCTAssertEqual(locator, "tcp/192.168.1.1:7447")
    }

    func testEmptyEnvironmentValueFallsThroughToDefault() {
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: [], environment: [HarnessCLI.zenohLocatorEnvVar: ""])
        XCTAssertEqual(locator, HarnessCLI.defaultZenohLocator)
    }

    func testLocatorFollowedByAnotherFlagFallsThrough() {
        // `--locator --duration-s 5` must not eat the flag as the value —
        // a locator never legitimately starts with `-`.
        let locator = HarnessCLI.resolveZenohLocator(
            arguments: ["rcl-soak", "zenoh", "--locator", "--duration-s", "5"],
            environment: [HarnessCLI.zenohLocatorEnvVar: "tcp/192.168.1.1:7447"])
        XCTAssertEqual(locator, "tcp/192.168.1.1:7447")
    }

    func testStackForBackendIsSelfDescribing() {
        XCTAssertEqual(HarnessCLI.stack(forBackend: "rcl"), "rcl-rmw_cyclonedds")
        XCTAssertEqual(HarnessCLI.stack(forBackend: "dds"), "wire-cyclonedds")
        // Mirrors makeDefaultSession's `.zenoh` routing: on Linux RCL builds
        // rcl + rmw_zenoh_cpp wins even though zenoh-pico stays linked.
        #if os(Linux) && SWIFT_ROS2_RCL
            XCTAssertEqual(HarnessCLI.stack(forBackend: "zenoh"), "rcl-rmw_zenoh")
        #elseif canImport(SwiftROS2Zenoh)
            XCTAssertEqual(HarnessCLI.stack(forBackend: "zenoh"), "wire-zenoh-pico")
        #else
            XCTAssertEqual(HarnessCLI.stack(forBackend: "zenoh"), "rcl-rmw_zenoh")
        #endif
    }
}
