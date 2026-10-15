import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2TestSupport
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

final class ParameterEventTests: XCTestCase {
    private func makeContext(
        startParameterServices: Bool = true
    ) async throws -> (ROS2Context, MockTransportSession, ROS2Node) {
        let session = MockTransportSession()
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447"),
            distro: .jazzy,
            session: session
        )
        let node = try await ctx.createNode(
            name: "events_node",
            namespace: "/test",
            options: ROS2NodeOptions(startParameterServices: startParameterServices)
        )
        return (ctx, session, node)
    }

    private func decodedEvents(
        on session: MockTransportSession
    ) -> [ParameterEvent] {
        // Find the publisher created for /test/events_node/parameter_events.
        guard let pub = session.publishers.first(where: { $0.topic.hasSuffix("/parameter_events") })
        else { return [] }
        return pub.publishedPayloads.compactMap { payload in
            guard let dec = try? CDRDecoder(data: payload.data, isLegacySchema: false) else { return nil }
            return try? ParameterEvent(from: dec)
        }
    }

    /// `dispatchParameterEvent` runs in a detached `Task`, so events arrive
    /// asynchronously after the parameter mutation returns; poll for them.
    private func waitForEvents(on session: MockTransportSession, atLeast count: Int) async {
        await waitUntil { decodedEvents(on: session).count >= count }
    }

    /// For the opt-out case, where no event is ever expected: give the system a short fixed window to
    /// emit a stray event before sampling.
    private func settleEventQueue() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    func testDeclareEmitsNewParameterEvent() async throws {
        let (ctx, session, node) = try await makeContext()
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        await waitForEvents(on: session, atLeast: 1)
        let events = decodedEvents(on: session)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.newParameters.count, 1)
        XCTAssertEqual(events.first?.newParameters.first?.name, "rate")
        XCTAssertEqual(events.first?.node, "/test/events_node")
    }

    func testSetEmitsChangedParameterEvent() async throws {
        let (ctx, session, node) = try await makeContext()
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        _ = await node.setParameter(ROS2Parameter(name: "rate", value: .integer(60)))
        await waitForEvents(on: session, atLeast: 2)
        let events = decodedEvents(on: session)
        XCTAssertEqual(events.count, 2)  // declare + set
        // Publishing happens through detached Tasks so ordering is best-effort.
        let changedNames = events.flatMap { $0.changedParameters }.map { $0.name }
        XCTAssertEqual(changedNames, ["rate"])
    }

    func testUndeclareEmitsDeletedParameterEvent() async throws {
        let (ctx, session, node) = try await makeContext()
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        try await node.undeclareParameter("rate")
        await waitForEvents(on: session, atLeast: 2)
        let events = decodedEvents(on: session)
        XCTAssertEqual(events.count, 2)
        let deletedNames = events.flatMap { $0.deletedParameters }.map { $0.name }
        XCTAssertEqual(deletedNames, ["rate"])
    }

    func testVetoedSetEmitsNoEvent() async throws {
        let (ctx, session, node) = try await makeContext()
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        _ = await node.setOnSetParametersCallback { _ in .failure(reason: "no") }
        _ = await node.setParameter(ROS2Parameter(name: "rate", value: .integer(60)))
        // A later successful declare follows the vetoed set; once its event has landed, the vetoed
        // set's event would have too, so there must be exactly the two declare events.
        _ = try await node.declareParameter("fps", default: Int64(10))
        await waitForEvents(on: session, atLeast: 2)
        let events = decodedEvents(on: session)
        XCTAssertEqual(events.flatMap { $0.newParameters }.map { $0.name }.sorted(), ["fps", "rate"])
        XCTAssertTrue(events.allSatisfy { $0.changedParameters.isEmpty }, "the vetoed set emitted an event")
    }

    func testOptOutNodeNeverCreatesEventPublisher() async throws {
        let (ctx, session, node) = try await makeContext(startParameterServices: false)
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        // Opt-out node: emitter is never installed, so no publisher should
        // be created. Settle briefly so any phantom emit would surface.
        await settleEventQueue()
        let pub = session.publishers.first(where: { $0.topic.hasSuffix("/parameter_events") })
        XCTAssertNil(pub)
    }

    func testEventPublisherTopicAndQoS() async throws {
        let (ctx, session, node) = try await makeContext()
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        await waitForEvents(on: session, atLeast: 1)
        let pub = session.publishers.first(where: { $0.topic.hasSuffix("/parameter_events") })
        XCTAssertNotNil(pub)
        // ROS 2 publishes /parameter_events on the *root* namespace, not under
        // the node FQN. Both rclcpp and rclpy do this — the topic is global.
        XCTAssertEqual(pub?.topic, "/parameter_events")
        XCTAssertEqual(pub?.qos.reliability, .reliable)
        XCTAssertEqual(pub?.qos.durability, .transientLocal)
    }
}
