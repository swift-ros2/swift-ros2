// RclRuntimeZenohGateTests.swift
// Runtime mirror of the zenoh-variant fail-loud gate (RclZenohFailLoudTests):
// on Linux the rmw is selected at RUNTIME from the transport type, so a
// build without SWIFT_ROS2_RCL_RMW_ZENOH can still open a zenoh-backed rcl
// context. A marshal-registry miss there must NOT fall back to the route-(b)
// raw-CDR CycloneDDS sibling — the rcl graph speaks Zenoh, so route-(b)
// traffic has no counterpart (silent data loss). The gate must key on the
// captured context transport, not only on the compile-time variant.
//
// Compiled only where the compile-time gate is absent; the zenoh-rmw variant
// keeps its static gate coverage in RclZenohFailLoudTests.

#if SWIFT_ROS2_RCL && !SWIFT_ROS2_RCL_RMW_ZENOH
    import Foundation
    import SwiftROS2RCL
    import SwiftROS2Transport
    import XCTest

    /// Stand-in node handle: the registry-miss gate fires before the node
    /// handle is inspected, so these tests need no rcl context or node.
    private final class FakeNodeHandle: RclNodeHandle {}

    final class RclRuntimeZenohGateTests: XCTestCase {
        private let absentType = "foo_msgs/msg/Bar"

        /// Capture a `.zenoh` transport intent WITHOUT starting rmw: the
        /// non-embeddable locator (embedded quote) fails createContext after
        /// the transport type is captured but before any rcl call, and every
        /// env slot the attempt applied is restored on that failure path.
        private func makeZenohBackedClient() -> RclClient {
            let client = RclClient()
            XCTAssertThrowsError(
                try client.createContext(
                    domainId: 87, transportType: .zenoh, unicastPeerAddresses: [],
                    networkInterface: nil, zenohRouterLocator: "tcp/127.0.0.1:7447\"oops")
            ) { error in
                guard case TransportError.invalidConfiguration = error else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
            }
            return client
        }

        private func assertRegistryMissError(_ error: Error) {
            guard case TransportError.unsupportedFeature(let message) = error else {
                return XCTFail("expected unsupportedFeature, got \(error)")
            }
            XCTAssertTrue(message.contains(absentType), "type name missing from: \(message)")
        }

        func testCreatePublisherThrowsOnRegistryMissWhenZenohBacked() {
            let client = makeZenohBackedClient()
            XCTAssertThrowsError(
                try client.createPublisher(
                    node: FakeNodeHandle(), typeName: absentType, typeHash: nil,
                    topic: "/gate_pub", qos: .sensorData)
            ) { assertRegistryMissError($0) }
        }

        func testCreateSubscriptionThrowsOnRegistryMissWhenZenohBacked() {
            let client = makeZenohBackedClient()
            XCTAssertThrowsError(
                try client.createSubscription(
                    node: FakeNodeHandle(), typeName: absentType, typeHash: nil,
                    topic: "/gate_sub", qos: .sensorData, handler: { _, _ in })
            ) { assertRegistryMissError($0) }
        }

        func testBundledTypePassesRuntimeGate() {
            // A bundled type must get past the gate and fail on the (fake) node
            // handle instead — the gate keys on the registry, not on the
            // transport as a whole.
            let client = makeZenohBackedClient()
            XCTAssertThrowsError(
                try client.createPublisher(
                    node: FakeNodeHandle(), typeName: "sensor_msgs/msg/Imu", typeHash: nil,
                    topic: "/gate_bundled", qos: .sensorData)
            ) { error in
                guard case TransportError.publisherCreationFailed(let message) = error else {
                    return XCTFail("expected publisherCreationFailed, got \(error)")
                }
                XCTAssertTrue(message.contains("invalid node handle"), "unexpected: \(message)")
            }
        }

        func testRequireBundledTypesupportIsAvailableOutsideZenohVariant() {
            // The gate helper itself must compile (and accept bundled types) on
            // every RCL arm, not only under SWIFT_ROS2_RCL_RMW_ZENOH.
            XCTAssertNoThrow(try RclClient.requireBundledTypesupport("sensor_msgs/msg/Imu"))
        }
    }
#endif
