import Foundation
import SwiftROS2TestSupport
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

final class ParameterCallbacksTests: XCTestCase {
    private func declared(_ store: ParameterStore, _ name: String, _ value: ROS2ParameterValue) async throws {
        _ = try await store.declare(
            name: name, value: value,
            descriptor: ROS2ParameterDescriptor(name: name, type: value.parameterType))
    }

    private func makeContext() async throws -> ROS2Context {
        let config = TransportConfig.zenoh(locator: "tcp/mock:7447")
        let mock = MockTransportSession()
        mock.installEchoServiceTransport()
        return try await ROS2Context(transport: config, session: mock)
    }

    func testPreSetMutatesProposedList() async throws {
        let store = ParameterStore()
        try await declared(store, "rate", .integer(30))
        _ = await store.registerPreSet { ps in
            ps = ps.map {
                if $0.name == "rate", case .integer(let v) = $0.value {
                    return ROS2Parameter(name: "rate", value: .integer(v * 2))
                }
                return $0
            }
        }
        let r = await store.set(ROS2Parameter(name: "rate", value: .integer(20)))
        XCTAssertTrue(r.successful)
        let stored = try await store.get(name: "rate")
        XCTAssertEqual(stored.value, .integer(40))
    }

    func testOnSetVetoBlocksWrite() async throws {
        let store = ParameterStore()
        try await declared(store, "rate", .integer(30))
        _ = await store.registerOnSet { _ in .failure(reason: "vetoed") }
        let r = await store.set(ROS2Parameter(name: "rate", value: .integer(20)))
        XCTAssertFalse(r.successful)
        XCTAssertEqual(r.reason, "vetoed")
        let stored = try await store.get(name: "rate")
        XCTAssertEqual(stored.value, .integer(30))
    }

    func testPostSetSeesOnlySuccesses() async throws {
        let store = ParameterStore()
        try await declared(store, "a", .integer(1))
        try await declared(store, "b", .integer(2))
        actor Box {
            var seen: [ROS2Parameter] = []
            func add(_ ps: [ROS2Parameter]) { seen += ps }
        }
        let box = Box()
        _ = await store.registerPostSet { ps in Task { await box.add(ps) } }
        _ = await store.setMany([
            ROS2Parameter(name: "a", value: .integer(10)),
            ROS2Parameter(name: "missing", value: .integer(0)),
            ROS2Parameter(name: "b", value: .integer(20)),
        ])
        // Wait (bounded poll, not a fixed sleep) for the detached Task posting
        // into Box to drain.
        // The post-set callback runs in a detached task: wait for it to observe the two successful sets.
        await waitUntil { await box.seen.count >= 2 }
        let names = await box.seen.map { $0.name }
        XCTAssertEqual(names.sorted(), ["a", "b"])
    }

    func testSetAtomicallyVetoLeavesNothingChanged() async throws {
        let store = ParameterStore()
        try await declared(store, "a", .integer(1))
        try await declared(store, "b", .integer(2))
        _ = await store.registerOnSet { _ in .failure(reason: "no") }
        let r = await store.setAtomically([
            ROS2Parameter(name: "a", value: .integer(10)),
            ROS2Parameter(name: "b", value: .integer(20)),
        ])
        XCTAssertFalse(r.successful)
        let a = try await store.get(name: "a")
        let b = try await store.get(name: "b")
        XCTAssertEqual(a.value, .integer(1))
        XCTAssertEqual(b.value, .integer(2))
    }

    func testNodeOnSetCallbackVetoesViaSet() async throws {
        let ctx = try await makeContext()
        let node = try await ctx.createNode(name: "n1")
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        _ = await node.setOnSetParametersCallback { _ in
            ROS2SetParametersResult(successful: false, reason: "guarded")
        }
        let r = await node.setParameter(ROS2Parameter(name: "rate", value: .integer(99)))
        XCTAssertFalse(r.successful)
        XCTAssertEqual(r.reason, "guarded")
    }

    func testNodeRemoveParameterCallback() async throws {
        let ctx = try await makeContext()
        let node = try await ctx.createNode(name: "n2")
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))
        let h = await node.setOnSetParametersCallback { _ in
            ROS2SetParametersResult(successful: false, reason: "guarded")
        }
        let removed = await node.removeParameterCallback(h)
        XCTAssertTrue(removed)
        let r = await node.setParameter(ROS2Parameter(name: "rate", value: .integer(99)))
        XCTAssertTrue(r.successful)
    }

    func testRemovedCallbackStopsFiring() async throws {
        let store = ParameterStore()
        try await declared(store, "a", .integer(1))
        // Post-set callbacks are synchronous (`@Sendable ([ROS2Parameter]) -> Void`)
        // and invoked inline by the store before `set` returns, so a lock-guarded
        // counter observes them deterministically the moment `set` resumes.
        // This also makes the negative assertion (callback must NOT fire after
        // removal) exact instead of a sleep-and-hope check.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let c = Counter()
        let h = await store.registerPostSet { _ in c.increment() }
        _ = await store.set(ROS2Parameter(name: "a", value: .integer(2)))
        XCTAssertEqual(c.count, 1)
        let removed = await store.unregisterCallback(h)
        XCTAssertTrue(removed)
        _ = await store.set(ROS2Parameter(name: "a", value: .integer(3)))
        XCTAssertEqual(c.count, 1, "removed post-set callback must not fire again")
    }
}
