import Foundation
import XCTest

@testable import SwiftROS2Transport

final class ZenohServiceTransportTests: XCTestCase {
    func testServerHandlerInvokedAndReplies() async throws {
        let zenoh = MockZenohClient()
        let session = ZenohTransportSession(client: zenoh)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447"))

        let received = Box<Data?>(nil)
        _ = try session.createServiceServer(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData,
            handler: { req in
                received.value = req
                return Data([0x00, 0x01, 0x00, 0x00, 0xCC])
            }
        )

        zenoh.deliverQueryToQueryable(
            keyExpr: "0/echo/std_srvs::srv::dds_::Trigger_",
            payload: Data([0x00, 0x01, 0x00, 0x00, 0xDE]),
            attachment: nil
        )
        try await zenoh.awaitQueryReply(timeout: .seconds(1))

        XCTAssertEqual(received.value, Data([0x00, 0x01, 0x00, 0x00, 0xDE]))
        XCTAssertEqual(zenoh.lastQueryReplyPayload, Data([0x00, 0x01, 0x00, 0x00, 0xCC]))
    }

    func testClientGetReturnsReply() async throws {
        let zenoh = MockZenohClient()
        let session = ZenohTransportSession(client: zenoh)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447"))

        let cli = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )

        zenoh.scriptGetReply(payload: Data([0x00, 0x01, 0x00, 0x00, 0xEE]), isError: false)
        let result = try await cli.call(
            requestCDR: Data([0x00, 0x01, 0x00, 0x00, 0xDE]),
            timeout: .seconds(1)
        )
        XCTAssertEqual(result, Data([0x00, 0x01, 0x00, 0x00, 0xEE]))
    }

    func testClientGetTimeoutSurfacesAsRequestTimeout() async throws {
        let zenoh = MockZenohClient()
        let session = ZenohTransportSession(client: zenoh)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447"))
        let cli = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )
        zenoh.scriptGetTimeout()
        do {
            _ = try await cli.call(requestCDR: Data([0x00, 0x01, 0x00, 0x00]), timeout: .seconds(1))
            XCTFail("should have thrown timeout")
        } catch TransportError.requestTimeout {
            // expected
        }
    }

    func testClientGetErrorReplyMapsToHandlerFailed() async throws {
        let zenoh = MockZenohClient()
        let session = ZenohTransportSession(client: zenoh)
        try await session.open(config: .zenoh(locator: "tcp/127.0.0.1:7447"))
        let cli = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )
        zenoh.scriptGetReply(payload: Data("boom".utf8), isError: true)
        do {
            _ = try await cli.call(requestCDR: Data([0x00, 0x01, 0x00, 0x00]), timeout: .seconds(1))
            XCTFail("should have thrown handler failed")
        } catch TransportError.serviceHandlerFailed(let msg) {
            XCTAssertEqual(msg, "boom")
        }
    }
}
