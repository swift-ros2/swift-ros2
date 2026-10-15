// ContextOpenFailureTests.swift
// A failed session open reports the open error and releases what it left behind.

import Foundation
import XCTest

@testable import SwiftROS2
@testable import SwiftROS2Transport

final class ContextOpenFailureTests: XCTestCase {
    private static let zenoh = TransportConfig.zenoh(locator: "tcp/127.0.0.1:7447")

    func testOpenErrorPropagatesAndTheSessionIsClosed() async throws {
        let mock = MockTransportSession()
        mock.isConnected = false
        mock.openShouldThrow = .connectionFailed("router unreachable")
        do {
            _ = try await ROS2Context(transport: Self.zenoh, distro: .jazzy, session: mock)
            XCTFail("Expected the open error")
        } catch let error as TransportError {
            guard case .connectionFailed(let message) = error else {
                return XCTFail("Wrong error: \(error)")
            }
            XCTAssertEqual(message, "router unreachable")
        }
        XCTAssertEqual(mock.closedCount, 1)
    }

    func testFailingCleanupDoesNotMaskTheOpenError() async throws {
        let mock = MockTransportSession()
        mock.isConnected = false
        mock.openShouldThrow = .connectionTimeout(1)
        mock.closeShouldThrow = .sessionClosed
        do {
            _ = try await ROS2Context(transport: Self.zenoh, distro: .jazzy, session: mock)
            XCTFail("Expected the open error")
        } catch let error as TransportError {
            guard case .connectionTimeout = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
        XCTAssertEqual(mock.closedCount, 1)
    }

    func testConnectedSessionIsNotOpenedOrClosed() async throws {
        let mock = MockTransportSession()
        let ctx = try await ROS2Context(transport: Self.zenoh, distro: .jazzy, session: mock)
        XCTAssertTrue(mock.openedConfigs.isEmpty)
        XCTAssertEqual(mock.closedCount, 0)
        await ctx.shutdown()
    }

    #if canImport(SwiftROS2Zenoh) && !(os(Linux) && SWIFT_ROS2_RCL)
        /// A real wire Zenoh session against a local port (tcpmux) nobody listens on.
        func testUnreachableLocatorReportsTheConnectionFailure() async throws {
            do {
                _ = try await ROS2Context(
                    transport: .zenoh(locator: "tcp/127.0.0.1:1", connectionTimeout: 5))
                XCTFail("Expected the open error")
            } catch let error as TransportError {
                guard case .connectionFailed = error else {
                    return XCTFail("Wrong error: \(error)")
                }
            }
        }
    #endif
}
