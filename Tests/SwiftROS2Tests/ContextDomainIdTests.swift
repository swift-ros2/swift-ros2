// ContextDomainIdTests.swift
// `ROS2Context(transport:distro:domainId:)`: an explicit domainId wins over the
// transport's, and the session is opened on it.

import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

final class ContextDomainIdTests: XCTestCase {
    func testExplicitDomainIdOpensTheSessionOnIt() async throws {
        let mock = unopenedSession()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", wireMode: .lyrical),
            distro: .lyrical, domainId: 123, session: mock)

        XCTAssertEqual(mock.openedConfigs.count, 1)
        let opened = try XCTUnwrap(mock.openedConfigs.first)
        XCTAssertEqual(opened.domainId, 123)
        XCTAssertEqual(opened.zenohLocator, "tcp/127.0.0.1:7447")
        XCTAssertEqual(opened.wireMode, .lyrical)
        XCTAssertEqual(ctx.domainId, 123)
        XCTAssertEqual(ctx.config.domainId, 123)
        await ctx.shutdown()
    }

    func testWithoutDomainIdTheTransportsDomainIsUsed() async throws {
        let mock = unopenedSession()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 42), session: mock)
        XCTAssertEqual(mock.openedConfigs.first?.domainId, 42)
        XCTAssertEqual(ctx.domainId, 42)
        XCTAssertEqual(ctx.config.domainId, 42)
        await ctx.shutdown()
    }

    func testExplicitDomainIdMatchingTheTransportsIsANoOp() async throws {
        let mock = unopenedSession()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/127.0.0.1:7447", domainId: 7), domainId: 7, session: mock)
        XCTAssertEqual(mock.openedConfigs.first?.domainId, 7)
        XCTAssertEqual(ctx.domainId, 7)
        await ctx.shutdown()
    }

    func testOutOfRangeDomainIdIsRejected() async throws {
        let mock = unopenedSession()
        do {
            _ = try await ROS2Context(
                transport: .zenoh(locator: "tcp/127.0.0.1:7447"), domainId: 233, session: mock)
            XCTFail("expected invalidConfiguration for domain 233")
        } catch TransportError.invalidConfiguration {
            // expected: the overridden configuration fails validate()
        }
        XCTAssertTrue(mock.openedConfigs.isEmpty)
    }

    #if canImport(SwiftROS2DDS)
        /// The default DDS session is made and opened on the overridden domain.
        func testDefaultDDSSessionOpensOnTheExplicitDomain() async throws {
            let ctx = try await ROS2Context(transport: .ddsMulticast(domainId: 0), domainId: 219)
            XCTAssertEqual(ctx.domainId, 219)
            XCTAssertEqual(ctx.config.domainId, 219)
            XCTAssertEqual(ctx.config.type, .dds)
            await ctx.shutdown()
        }
    #endif

    /// A mock session the context still has to open, so `openedConfigs`
    /// records the configuration the context opens it with.
    private func unopenedSession() -> MockTransportSession {
        let mock = MockTransportSession()
        mock.isConnected = false
        return mock
    }
}
