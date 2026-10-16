// WireModeMismatchTests.swift
// A ROS2Context whose explicit TransportConfig.wireMode differs from its distro logs one warning.

import SwiftROS2Transport
import SwiftROS2Wire
import XCTest

@testable import SwiftROS2

final class WireModeMismatchTests: XCTestCase {
    /// Collects the lines a context logs.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _lines
        }

        func append(_ line: String) {
            lock.lock()
            _lines.append(line)
            lock.unlock()
        }
    }

    private func makeContext(
        wireMode: ROS2Distro?, distro: ROS2Distro, log: LogBox
    ) async throws -> (ROS2Context, MockTransportSession) {
        let session = MockTransportSession()
        session.isConnected = false
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", wireMode: wireMode),
            distro: distro, domainId: nil, session: session, log: { log.append($0) })
        return (ctx, session)
    }

    func testDifferingWireModeIsLoggedOnceAndStillWins() async throws {
        let log = LogBox()
        let (ctx, session) = try await makeContext(wireMode: .humble, distro: .lyrical, log: log)
        XCTAssertEqual(log.lines.count, 1)
        let line = try XCTUnwrap(log.lines.first)
        XCTAssertTrue(line.contains("humble"), line)
        XCTAssertTrue(line.contains("lyrical"), line)
        // The warning changes nothing: the explicit wireMode is still what the session opens with.
        XCTAssertEqual(session.openedConfigs.first?.wireMode, .humble)
        XCTAssertEqual(ctx.distro, .lyrical)
        await ctx.shutdown()
    }

    func testMatchingWireModeIsNotLogged() async throws {
        let log = LogBox()
        let (ctx, _) = try await makeContext(wireMode: .jazzy, distro: .jazzy, log: log)
        XCTAssertEqual(log.lines, [])
        await ctx.shutdown()
    }

    func testUnsetWireModeIsNotLogged() async throws {
        let log = LogBox()
        let (ctx, session) = try await makeContext(wireMode: nil, distro: .lyrical, log: log)
        XCTAssertEqual(log.lines, [])
        XCTAssertEqual(session.openedConfigs.first?.wireMode, .lyrical)
        await ctx.shutdown()
    }

    func testWarningFunctionCoversEveryPair() {
        for wireMode in ROS2Distro.allCases {
            for distro in ROS2Distro.allCases {
                let line = WireModeMismatch.warning(wireMode: wireMode, distro: distro)
                XCTAssertEqual(line != nil, wireMode != distro, "\(wireMode) vs \(distro)")
            }
            XCTAssertNil(WireModeMismatch.warning(wireMode: nil, distro: wireMode))
        }
    }
}
