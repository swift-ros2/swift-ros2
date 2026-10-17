#if SWIFT_ROS2_RCL && !SWIFT_ROS2_RCL_RMW_ZENOH && !os(Windows)
    import Foundation
    import SwiftROS2RCL
    import SwiftROS2Transport
    import XCTest

    /// A route-(b) subscription (a type in no marshal registry, read by RclClient's
    /// raw-CDR reader below rmw) that is transient-local and created after a route-(b)
    /// publisher in the same context published gets the cached sample before
    /// `createSubscription` returns, exactly once.
    ///
    /// The writer and the reader share the context's raw CycloneDDS participant, so
    /// CycloneDDS hands the sample to the reader while it is being created and no
    /// listener call follows for it: only the client's drain after the create passes
    /// it on.
    ///
    /// Domain 81 is used by no other test: rmw_cyclonedds_cpp creates a domain once
    /// per id and process, and a wire DDS session never deletes the domain it
    /// created, so it must differ from every wire DDS test domain (see
    /// RclSignalMaskTests).
    final class RclRouteBLateJoinerTests: XCTestCase {
        func testLateTransientLocalRouteBSubscriptionGetsTheCachedSampleOnce() async throws {
            let client = RclClient()
            try client.createContext(
                domainId: 81, transportType: .dds, unicastPeerAddresses: [],
                networkInterface: nil, zenohRouterLocator: nil)
            defer { client.destroyContext() }
            let node = try client.createNode(name: "route_b_late_joiner_test", namespace: "/")
            defer { client.destroyNode(node) }

            // In no marshal registry, so both endpoints take route (b).
            let type = "swift_ros2_test_msgs/msg/Blob"
            let topic = "/swift_ros2_route_b_late_joiner"
            let qos = TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1))
            let publisher = try client.createPublisher(
                node: node, typeName: type, typeHash: nil, topic: topic, qos: qos)
            defer { publisher.close() }
            let sample = Data([0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x68, 0x69, 0x00, 0x00])
            try client.publishSerialized(publisher, data: sample)

            let received = RouteBSamples()
            let subscription = try client.createSubscription(
                node: node, typeName: type, typeHash: nil, topic: topic, qos: qos,
                handler: { data, _ in received.append(data) })
            defer { client.destroySubscription(subscription) }

            XCTAssertEqual(received.all, [sample], "delivered before createSubscription returned")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(received.all, [sample], "and not again")
        }
    }

    private final class RouteBSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            samples.append(data)
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }
#endif
