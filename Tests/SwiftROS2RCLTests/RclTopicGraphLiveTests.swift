#if SWIFT_ROS2_RCL
    import CRclBridge
    import Foundation
    import SwiftROS2
    import SwiftROS2TestFixtures
    import SwiftROS2Transport
    import XCTest

    /// The QoS values `crcl_graph_snapshot` reports are the ones the RCL session maps.
    final class RclGraphConstantsTests: XCTestCase {
        func testSwiftRmwConstantsMatchTheBridge() {
            XCTAssertEqual(Int32(CRCL_RMW_RELIABILITY_RELIABLE), RclGraphPublisherRecord.rmwReliabilityReliable)
            XCTAssertEqual(
                Int32(CRCL_RMW_DURABILITY_TRANSIENT_LOCAL), RclGraphPublisherRecord.rmwDurabilityTransientLocal)
        }
    }
#endif

#if SWIFT_ROS2_RCL && !SWIFT_ROS2_RCL_RMW_ZENOH && !os(Windows)
    /// `ROS2Context.topicGraph()` against a real rcl + rmw_cyclonedds_cpp context.
    ///
    /// The first `topicGraph()` call creates the graph node, and here it is the
    /// context's first node, so it is what makes rmw_cyclonedds_cpp create the
    /// CycloneDDS domain and start its threads, on the session's graph queue. The
    /// main thread's signal mask must survive that (#290).
    ///
    /// Domain 76 is used by no other test: rmw_cyclonedds_cpp creates a domain once
    /// per id and process, and a wire DDS session in the same process (the macOS CI
    /// toolchain runs every test target in one process) never deletes its domain.
    final class RclTopicGraphLiveTests: XCTestCase {
        func testListsOwnPublishersWithQoSAndNode() throws {
            XCTAssertTrue(Thread.isMainThread)
            let mainBefore = Self.blockedSignals()

            let outcome = OutcomeBox()
            let context = ContextBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    outcome.set(.success(try await Self.runGraph(context: context)))
                } catch {
                    outcome.set(.failure(error))
                }
                done.signal()
            }
            guard done.wait(timeout: .now() + 60) == .success else {
                XCTFail("the graph run did not finish in time")
                // Do not leave the context running for the tests after this one.
                // The shutdown waits for a snapshot in flight, so bound it too.
                if let ctx = context.get() {
                    let shutDown = DispatchSemaphore(value: 0)
                    Task.detached {
                        await ctx.shutdown()
                        shutDown.signal()
                    }
                    _ = shutDown.wait(timeout: .now() + 10)
                }
                return
            }

            let graph = try XCTUnwrap(outcome.get()).get()
            XCTAssertEqual(Self.blockedSignals(), mainBefore, "the main thread's signal mask changed")

            let latched = try XCTUnwrap(graph.first { $0.name == "/graph_live/latched" }, "\(graph)")
            XCTAssertEqual(latched.typeName, "std_msgs/msg/String")
            XCTAssertEqual(
                latched.publishers,
                [
                    EndpointQoS(
                        reliability: .reliable, durability: .transientLocal, nodeName: "graph_live",
                        nodeNamespace: "/graph_live")
                ])
            let imu = try XCTUnwrap(graph.first { $0.name == "/graph_live/imu" }, "\(graph)")
            XCTAssertEqual(imu.typeName, "sensor_msgs/msg/Imu")
            XCTAssertEqual(
                imu.publishers,
                [
                    EndpointQoS(
                        reliability: .bestEffort, durability: .volatile, nodeName: "graph_live",
                        nodeNamespace: "/graph_live")
                ])
            // The graph node itself publishes nothing.
            XCTAssertFalse(
                graph.contains { $0.publishers.contains { $0.nodeName == "_swift_ros2_graph" } }, "\(graph)")
        }

        /// Opens the context, reads the graph before any node exists, then creates the
        /// publishers and polls until both are listed. Returns the last graph.
        /// Puts the context in `context` so a timed-out caller can shut it down.
        private static func runGraph(context: ContextBox) async throws -> [TopicInfo] {
            let ctx = try await ROS2Context(transport: .rcl(domainId: 76))
            context.set(ctx)
            do {
                _ = try await ctx.topicGraph()
                let node = try await ctx.createNode(name: "graph_live", namespace: "/graph_live")
                let latched = try await node.createPublisher(StringMsg.self, topic: "latched", qos: .latched)
                let imu = try await node.createPublisher(Imu.self, topic: "imu", qos: .sensorData)
                var graph: [TopicInfo] = []
                let deadline = ContinuousClock.now + .seconds(15)
                while ContinuousClock.now < deadline {
                    graph = try await ctx.topicGraph()
                    let names = Set(graph.map(\.name))
                    if names.isSuperset(of: ["/graph_live/latched", "/graph_live/imu"]) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                withExtendedLifetime((latched, imu)) {}
                await ctx.shutdown()
                do {
                    _ = try await ctx.topicGraph()
                    throw TransportError.invalidConfiguration("topicGraph() after shutdown did not throw")
                } catch TransportError.notConnected {
                }
                return graph
            } catch {
                await ctx.shutdown()
                throw error
            }
        }

        /// The signals blocked on the current thread.
        private static func blockedSignals() -> [Int32] {
            var mask = sigset_t()
            pthread_sigmask(SIG_BLOCK, nil, &mask)
            return (1..<32).filter { sigismember(&mask, $0) == 1 }
        }
    }

    private final class ContextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ROS2Context?

        func set(_ newValue: ROS2Context) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> ROS2Context? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[TopicInfo], any Error>?

        func set(_ newValue: Result<[TopicInfo], any Error>) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Result<[TopicInfo], any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
#endif
