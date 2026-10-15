// DDSServiceTransportTests.swift
// DDS Service Server / Client end-to-end tests using MockDDSClient.

import Foundation
import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2Transport

final class DDSServiceTransportTests: XCTestCase {
    func testServerEchoesRequest() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))

        let received = Box<Data?>(nil)
        let server = try session.createServiceServer(
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

        let id = RMWRequestId(writerGuid: Array(repeating: 0xAB, count: 8), sequenceNumber: 7)
        let userCDR = Data([0x00, 0x01, 0x00, 0x00, 0xDE])
        let wire = SampleIdentityPrefix.encode(requestId: id, userCDR: userCDR)

        try await client.deliverToReader(topic: "rq/echoRequest", wire: wire, timestamp: 1_000)

        // The server runs the handler on a `Task.detached` so the reply may
        // already have landed by the time we ask for it; `awaitWrite` returns
        // immediately if so, otherwise suspends until the write arrives.
        let written = try await client.awaitWrite(topic: "rr/echoReply", timeout: .seconds(5))
        let writtenBytes = try XCTUnwrap(written)

        XCTAssertEqual(received.value, userCDR)

        let (parsedId, parsedBody) = try SampleIdentityPrefix.decode(wirePayload: writtenBytes)
        XCTAssertEqual(parsedId, id)
        XCTAssertEqual(parsedBody, Data([0x00, 0x01, 0x00, 0x00, 0xCC]))
        try server.close()
    }

    func testClientWritesPrefixedRequestAndAwaitsReply() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))

        let svc = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )

        client.markPublicationsMatched(topic: "rq/echoRequest")

        let userRequest = Data([0x00, 0x01, 0x00, 0x00, 0xDE])
        // svc.call's timeout covers both the outgoing-request write and the
        // test-driven reply injection below. Keep it well above the
        // awaitWrite budget so a slow request write cannot time the call out
        // before this test gets to deliver the reply.
        async let response: Data = svc.call(requestCDR: userRequest, timeout: .seconds(30))

        let writtenWire = try await client.awaitWrite(topic: "rq/echoRequest", timeout: .seconds(5))
        let bytes = try XCTUnwrap(writtenWire)
        // [header (4) | guid (8) | seq (8) | body] — rmw_cyclonedds_cpp's cdds_request_header_t.
        XCTAssertEqual(bytes.count, 4 + 16 + 1)
        let (id, parsedReq) = try SampleIdentityPrefix.decode(wirePayload: bytes)
        XCTAssertEqual(parsedReq, userRequest)
        XCTAssertEqual(id.writerGuid.count, 8)
        XCTAssertEqual(id.sequenceNumber, 1)

        let userReply = Data([0x00, 0x01, 0x00, 0x00, 0xEE])
        let replyWire = SampleIdentityPrefix.encode(requestId: id, userCDR: userReply)
        try await client.deliverToReader(topic: "rr/echoReply", wire: replyWire, timestamp: 0)

        let body = try await response
        XCTAssertEqual(body, userReply)
        try svc.close()
    }

    /// Defensive regression test: `call(requestCDR:timeout:)` races the
    /// reply against `Task.sleep(for: timeout)`. A caller-supplied timeout
    /// large enough to overflow that conversion (e.g. `.seconds(Int.max)`,
    /// the same "no timeout" stand-in `ActionGoalHandle.result(timeout:
    /// nil)` uses for the action path) must not trap the process; it should
    /// be treated as "wait forever" instead. The reply is delivered from a
    /// separate task after a short delay to prove the call genuinely waits.
    func testClientWithHugeTimeoutDoesNotTrapAndWaitsForDelayedReply() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))

        let svc = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )

        client.markPublicationsMatched(topic: "rq/echoRequest")

        let userRequest = Data([0x00, 0x01, 0x00, 0x00, 0xDE])
        async let response: Data = svc.call(requestCDR: userRequest, timeout: .seconds(Int.max))

        let writtenWire = try await client.awaitWrite(topic: "rq/echoRequest", timeout: .seconds(5))
        let bytes = try XCTUnwrap(writtenWire)
        let (id, parsedReq) = try SampleIdentityPrefix.decode(wirePayload: bytes)
        XCTAssertEqual(parsedReq, userRequest)

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            let userReply = Data([0x00, 0x01, 0x00, 0x00, 0xEE])
            let replyWire = SampleIdentityPrefix.encode(requestId: id, userCDR: userReply)
            try? await client.deliverToReader(topic: "rr/echoReply", wire: replyWire, timestamp: 0)
        }

        let body = try await response
        XCTAssertEqual(body, Data([0x00, 0x01, 0x00, 0x00, 0xEE]))
        try svc.close()
    }

    func testClientTimesOut() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))
        let svc = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )
        client.markPublicationsMatched(topic: "rq/echoRequest")

        do {
            _ = try await svc.call(
                requestCDR: Data([0x00, 0x01, 0x00, 0x00]),
                timeout: .milliseconds(50)
            )
            XCTFail("should have timed out")
        } catch TransportError.requestTimeout {
            // expected
        }
        try svc.close()
    }

    func testClientCancellationPropagates() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))
        let svc = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )
        client.markPublicationsMatched(topic: "rq/echoRequest")

        let task = Task {
            try await svc.call(
                requestCDR: Data([0x00, 0x01, 0x00, 0x00]),
                timeout: .seconds(60)
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("should have been cancelled")
        } catch TransportError.requestCancelled {
            // expected
        }
        try svc.close()
    }

    /// Regression: `waitForService` must not return while only the request
    /// side has matched. Against an rmw_cyclonedds_cpp server the reply to the
    /// first call is lost when the server's reply writer has not matched our
    /// reply reader yet, so both directions have to be matched first.
    func testWaitForServiceWaitsForBothDirections() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))
        let svc = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )

        // Nothing matched.
        await assertWaitTimesOut(svc)

        // Request side only.
        client.markPublicationsMatched(topic: "rq/echoRequest")
        await assertWaitTimesOut(svc)

        // Both directions.
        client.markSubscriptionsMatched(topic: "rr/echoReply")
        try await svc.waitForService(timeout: .seconds(2))
        try svc.close()
    }

    func testWaitForServiceTimesOutWithOnlyTheReplySideMatched() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))
        let svc = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )
        client.markSubscriptionsMatched(topic: "rr/echoReply")
        await assertWaitTimesOut(svc)
        try svc.close()
    }

    /// The request writer and the reply reader carry the same rmw_cyclonedds_cpp
    /// `clientid` (ahead of the type hash), which makes an rmw_cyclonedds_cpp
    /// server wait for the reply path before it answers. Two clients get
    /// different ids.
    func testClientEndpointsShareAClientIdAheadOfTheTypeHash() async throws {
        let client = MockDDSClient()
        let session = DDSTransportSession(client: client)
        try await session.open(config: .ddsMulticast(domainId: 0))
        let a = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: "RIHS01_aa",
            responseTypeHash: "RIHS01_bb",
            qos: .sensorData
        )
        let b = try session.createServiceClient(
            name: "/echo",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: nil,
            responseTypeHash: nil,
            qos: .sensorData
        )

        let writers = client.writers.filter { $0.topic == "rq/echoRequest" }.compactMap(\.userData)
        let readers = client.readers.filter { $0.topic == "rr/echoReply" }.compactMap(\.userData)
        XCTAssertEqual(writers.count, 2)
        XCTAssertEqual(readers.count, 2)

        let pattern = #"^clientid=[0-9a-f]{2}(\.[0-9a-f]{1,2}){15};"#
        for ud in writers + readers {
            XCTAssertNotNil(ud.range(of: pattern, options: .regularExpression), "unexpected USER_DATA \(ud)")
        }
        let idA = String(writers[0].split(separator: ";")[0])
        XCTAssertEqual(writers[0], "\(idA);typehash=RIHS01_aa;")
        XCTAssertEqual(readers[0], "\(idA);typehash=RIHS01_bb;")
        let idB = String(writers[1].split(separator: ";")[0])
        XCTAssertEqual(writers[1], "\(idB);")
        XCTAssertEqual(readers[1], "\(idB);")
        XCTAssertNotEqual(idA, idB)

        // Servers keep the plain type-hash USER_DATA.
        let server = try session.createServiceServer(
            name: "/other",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: "RIHS01_cc",
            responseTypeHash: nil,
            qos: .sensorData,
            handler: { $0 }
        )
        XCTAssertEqual(client.readers.first { $0.topic == "rq/otherRequest" }?.userData, "typehash=RIHS01_cc;")

        try a.close()
        try b.close()
        try server.close()
    }

    func testClientServiceIDStringMatchesRmwCycloneDDSFormat() {
        let id: [UInt8] = [0x01, 0x0f, 0x10, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xab]
        XCTAssertEqual(DDSClientServiceID.string(id), "01.f.10.ff.0.0.0.0.0.0.0.0.0.0.0.ab")
        XCTAssertEqual(DDSClientServiceID.make().count, 16)
    }

    private func assertWaitTimesOut(
        _ svc: any TransportClient, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await svc.waitForService(timeout: .milliseconds(250))
            XCTFail("waitForService returned before the service was reachable both ways", file: file, line: line)
        } catch TransportError.requestTimeout {
            // expected
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
