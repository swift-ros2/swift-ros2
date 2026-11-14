// ActionServerGoalExpiryTests.swift
// A finished goal stays in ROS2ActionServer for `resultTimeout`, then goes.

import Foundation
import SwiftROS2ExampleInterfaces
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2CDR
@testable import SwiftROS2Transport

final class ActionServerGoalExpiryTests: XCTestCase {
    private typealias Server = ROS2ActionServer<_AcceptingHandler>

    private func makeServer(resultTimeout: Duration) -> (Server, TransportActionServerHandlers, MockActionServer) {
        let transport = MockActionServer()
        let server = Server(
            transport: transport, handler: _AcceptingHandler(), distro: .jazzy, resultTimeout: resultTimeout)
        let handlers = Server.makeHandlers(distro: .jazzy) { server }
        return (server, handlers, transport)
    }

    private func sendGoal(_ id: [UInt8], via handlers: TransportActionServerHandlers) async throws {
        let encoder = CDREncoder(isLegacySchema: false)
        encoder.writeEncapsulationHeader()
        try FibonacciAction.Goal(order: 1).encode(to: encoder)
        let (accepted, _, _) = try await handlers.onSendGoal(id, encoder.getData())
        XCTAssertTrue(accepted)
    }

    /// Waits until GetResult reports SUCCEEDED for `id`.
    private func waitForSuccess(_ id: [UInt8], via handlers: TransportActionServerHandlers) async throws {
        let ack = try await handlers.onGetResult(id)
        XCTAssertEqual(ack.status, ActionGoalStatus.succeeded.rawValue)
    }

    /// Waits until the latest published status array satisfies `predicate`.
    private func waitForStatus(
        _ transport: MockActionServer, _ predicate: ([ActionStatusEntry]) -> Bool
    ) async throws -> Bool {
        for _ in 0..<100 {
            if let last = transport.publishedStatuses.last, predicate(last) { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testFinishedGoalIsRemovedAfterResultTimeout() async throws {
        let (server, handlers, transport) = makeServer(resultTimeout: .milliseconds(100))
        defer { server.cancel() }
        let first = [UInt8](repeating: 0x01, count: 16)
        let second = [UInt8](repeating: 0x02, count: 16)

        try await sendGoal(first, via: handlers)
        try await waitForSuccess(first, via: handlers)
        try await Task.sleep(nanoseconds: 300_000_000)

        // The next status change sweeps the expired goal.
        try await sendGoal(second, via: handlers)
        try await waitForSuccess(second, via: handlers)

        let ack = try await handlers.onGetResult(first)
        XCTAssertEqual(ack.status, ActionGoalStatus.unknown.rawValue)
        let firstGone = try await waitForStatus(transport) { entries in
            !entries.contains { $0.uuid == first } && entries.contains { $0.uuid == second }
        }
        XCTAssertTrue(firstGone, "the expired goal is still in the status array")
    }

    func testFinishedGoalIsKeptWithinResultTimeout() async throws {
        let (server, handlers, transport) = makeServer(resultTimeout: .seconds(60))
        defer { server.cancel() }
        let first = [UInt8](repeating: 0x03, count: 16)
        let second = [UInt8](repeating: 0x04, count: 16)

        try await sendGoal(first, via: handlers)
        try await waitForSuccess(first, via: handlers)
        try await sendGoal(second, via: handlers)
        try await waitForSuccess(second, via: handlers)

        try await waitForSuccess(first, via: handlers)
        let bothListed = try await waitForStatus(transport) { entries in
            entries.contains { $0.uuid == first && $0.status == ActionGoalStatus.succeeded.rawValue }
                && entries.contains { $0.uuid == second && $0.status == ActionGoalStatus.succeeded.rawValue }
        }
        XCTAssertTrue(bothListed)
    }
}
