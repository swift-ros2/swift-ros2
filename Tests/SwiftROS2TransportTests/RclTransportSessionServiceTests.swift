import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2Transport

final class RclTransportSessionServiceTests: XCTestCase {
    private let addTwoInts = "example_interfaces/srv/AddTwoInts"
    private let requestId: [UInt8] = Array(0..<24)
    private let requestCDR = Data([0x00, 0x01, 0x00, 0x00, 0x11, 0x22])
    private let responseCDR = Data([0x00, 0x01, 0x00, 0x00, 0x33, 0x44])

    private func openSession(
        _ client: MockRclClient = MockRclClient(),
        registerNode: Bool = true
    ) async throws -> RclTransportSession {
        let s = RclTransportSession(client: client)
        try await s.open(config: .rcl(domainId: 0))
        if registerNode {
            try s.registerNode(name: "svc_node", namespace: "/ios")
        }
        return s
    }

    // MARK: - Service server

    func testCreateServiceServerRequiresNode() async throws {
        let s = try await openSession(registerNode: false)
        XCTAssertThrowsError(
            try s.createServiceServer(
                name: "/add_two_ints", serviceTypeName: addTwoInts,
                requestTypeHash: nil, responseTypeHash: nil, qos: .default,
                handler: { _ in Data() })
        ) { error in
            guard case TransportError.subscriberCreationFailed = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreateServiceServerRejectsEmptyNameAndType() async throws {
        let s = try await openSession()
        XCTAssertThrowsError(
            try s.createServiceServer(
                name: "", serviceTypeName: addTwoInts,
                requestTypeHash: nil, responseTypeHash: nil, qos: .default,
                handler: { _ in Data() })
        ) { error in
            guard case TransportError.invalidConfiguration = error else {
                return XCTFail("got \(error)")
            }
        }
        XCTAssertThrowsError(
            try s.createServiceServer(
                name: "/add_two_ints", serviceTypeName: "",
                requestTypeHash: nil, responseTypeHash: nil, qos: .default,
                handler: { _ in Data() })
        ) { error in
            guard case TransportError.invalidConfiguration = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreateServiceServerAttachesToCurrentNodeAndPassesQoS() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let qos = TransportQoS(
            reliability: .bestEffort, durability: .transientLocal, history: .keepLast(5))
        let server = try s.createServiceServer(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: qos,
            handler: { _ in Data() })
        XCTAssertEqual(client.servicesCreated.count, 1)
        XCTAssertEqual(client.servicesCreated.first?.serviceName, "/add_two_ints")
        XCTAssertEqual(client.servicesCreated.first?.srvTypeName, addTwoInts)
        XCTAssertEqual(client.servicesCreated.first?.qos, qos)
        XCTAssertTrue(client.servicesCreated.first?.node === client.nodeHandles.first)
        XCTAssertEqual(server.name, "/add_two_ints")
        XCTAssertTrue(server.isActive)
    }

    func testServiceServerDispatchesHandlerAndSendsResponse() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let receivedRequests = Box<[Data]>([])
        let response = responseCDR
        _ = try s.createServiceServer(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default,
            handler: { req in
                receivedRequests.value.append(req)
                return response
            })
        let service = client.servicesCreated[0]
        service.fire(requestCDR, requestId: requestId)
        let responded = await eventually { service.responsesSent.count == 1 }
        XCTAssertTrue(responded, "response was not sent within the timeout")
        XCTAssertEqual(receivedRequests.value, [requestCDR])
        XCTAssertEqual(service.responsesSent.first?.data, responseCDR)
        // The opaque request-id blob must be echoed back unmodified.
        XCTAssertEqual(service.responsesSent.first?.requestId, requestId)
    }

    func testServiceServerHandlerThrowsDropsResponse() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let handlerRan = Box<Bool>(false)
        _ = try s.createServiceServer(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default,
            handler: { _ in
                handlerRan.value = true
                throw TransportError.serviceHandlerFailed("boom")
            })
        let service = client.servicesCreated[0]
        service.fire(requestCDR, requestId: requestId)
        let ran = await eventually { handlerRan.value }
        XCTAssertTrue(ran)
        // Mirror the wire path: a throwing handler drops the request — give
        // the (would-be) response task time to misbehave, then assert nothing
        // was sent.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(service.responsesSent.isEmpty)
    }

    func testServiceServerCloseDestroysExactlyOnce() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createServiceServer(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default,
            handler: { _ in Data() })
        try server.close()
        try server.close()  // idempotent
        XCTAssertFalse(server.isActive)
        XCTAssertEqual(client.servicesDestroyed.count, 1)
        XCTAssertEqual(client.servicesDestroyed.first?.serviceName, "/add_two_ints")
    }

    func testCreateServiceServerDuringCloseDestroysAndThrows() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        // Interleave close() into the preflight-create-append window: the
        // just-created service must not escape teardown (wait thread joined
        // via destroy) and the caller must see notConnected.
        client.onCreateServiceServer = { try? s.close() }
        XCTAssertThrowsError(
            try s.createServiceServer(
                name: "/add_two_ints", serviceTypeName: addTwoInts,
                requestTypeHash: nil, responseTypeHash: nil, qos: .default,
                handler: { _ in Data() })
        ) { error in
            guard case TransportError.notConnected = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(client.servicesDestroyed.count, 1)
    }

    func testCreateServiceServerSurfacesUnsupportedTypeError() async throws {
        let client = MockRclClient()
        client.createServiceServerShouldThrow =
            .subscriberCreationFailed("unsupported service type: foo_msgs/srv/Bar")
        let s = try await openSession(client)
        XCTAssertThrowsError(
            try s.createServiceServer(
                name: "/bar", serviceTypeName: "foo_msgs/srv/Bar",
                requestTypeHash: nil, responseTypeHash: nil, qos: .default,
                handler: { _ in Data() })
        ) { error in
            guard case TransportError.subscriberCreationFailed(let msg) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(msg.contains("unsupported service type"))
        }
    }

    // MARK: - Service client

    func testCreateServiceClientAttachesToCurrentNodeAndPassesQoS() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let qos = TransportQoS(
            reliability: .reliable, durability: .volatile, history: .keepLast(7))
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: qos)
        XCTAssertEqual(client.serviceClientsCreated.count, 1)
        XCTAssertEqual(client.serviceClientsCreated.first?.serviceName, "/add_two_ints")
        XCTAssertEqual(client.serviceClientsCreated.first?.srvTypeName, addTwoInts)
        XCTAssertEqual(client.serviceClientsCreated.first?.qos, qos)
        XCTAssertTrue(client.serviceClientsCreated.first?.node === client.nodeHandles.first)
        XCTAssertEqual(serviceClient.name, "/add_two_ints")
        XCTAssertTrue(serviceClient.isActive)
    }

    func testClientCallCorrelatesInterleavedCalls() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        let reqA = Data([0x00, 0x01, 0x00, 0x00, 0x0A])
        let reqB = Data([0x00, 0x01, 0x00, 0x00, 0x0B])
        let respA = Data([0x00, 0x01, 0x00, 0x00, 0xA0])
        let respB = Data([0x00, 0x01, 0x00, 0x00, 0xB0])

        async let resultA = serviceClient.call(requestCDR: reqA, timeout: .seconds(5))
        async let resultB = serviceClient.call(requestCDR: reqB, timeout: .seconds(5))

        let box = client.serviceClientsCreated[0]
        let sent = await eventually { box.sentRequests.count == 2 }
        XCTAssertTrue(sent, "both requests should have been sent")
        // Sequence numbers are 1-based send order; map them by payload so the
        // assertion is independent of which call sent first.
        let seqA = Int64(box.sentRequests.firstIndex(of: reqA)! + 1)
        let seqB = Int64(box.sentRequests.firstIndex(of: reqB)! + 1)
        // Resolve out of order on purpose.
        box.fire(sequenceNumber: seqB, data: respB)
        box.fire(sequenceNumber: seqA, data: respA)

        let (a, b) = try await (resultA, resultB)
        XCTAssertEqual(a, respA)
        XCTAssertEqual(b, respB)
    }

    func testClientCallIgnoresUnknownSequenceNumber() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        async let result = serviceClient.call(requestCDR: requestCDR, timeout: .seconds(5))
        let box = client.serviceClientsCreated[0]
        let sent = await eventually { box.sentRequests.count == 1 }
        XCTAssertTrue(sent)
        box.fire(sequenceNumber: 999, data: Data([0xFF]))  // dropped silently
        box.fire(sequenceNumber: 1, data: responseCDR)
        let got = try await result
        XCTAssertEqual(got, responseCDR)
    }

    func testClientCallSendFailureThrows() async throws {
        let client = MockRclClient()
        client.sendRequestShouldThrow = .publishFailed("rcl_send_request failed")
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        do {
            _ = try await serviceClient.call(requestCDR: requestCDR, timeout: .seconds(1))
            XCTFail("expected publishFailed")
        } catch let e as TransportError {
            guard case .publishFailed = e else { return XCTFail("got \(e)") }
        }
    }

    func testClientCallRejectsShortRequest() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        do {
            _ = try await serviceClient.call(requestCDR: Data([0x00]), timeout: .seconds(1))
            XCTFail("expected invalidConfiguration")
        } catch let e as TransportError {
            guard case .invalidConfiguration = e else { return XCTFail("got \(e)") }
        }
    }

    func testClientCallTimesOutWithoutResponse() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        do {
            _ = try await serviceClient.call(requestCDR: requestCDR, timeout: .milliseconds(100))
            XCTFail("expected requestTimeout")
        } catch let e as TransportError {
            guard case .requestTimeout = e else { return XCTFail("got \(e)") }
        }
    }

    func testCloseDuringPendingCallResumesWithSessionClosed() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        let request = requestCDR
        let pendingCall = Task {
            try await serviceClient.call(requestCDR: request, timeout: .seconds(30))
        }
        let box = client.serviceClientsCreated[0]
        let sent = await eventually { box.sentRequests.count == 1 }
        XCTAssertTrue(sent)
        try serviceClient.close()
        do {
            _ = try await pendingCall.value
            XCTFail("expected sessionClosed")
        } catch let e as TransportError {
            guard case .sessionClosed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(client.serviceClientsDestroyed.count, 1)
        XCTAssertFalse(serviceClient.isActive)
    }

    /// Residual close-vs-call race: call() can snapshot closed=false/handle,
    /// then close() fully runs (failAll sweeps a still-empty table) before
    /// registerAndSend executes. The interleaving cannot be scheduled through
    /// the mock seam — registerAndSend holds the table lock across the send
    /// hook and failAll takes the same lock, so close() can never complete
    /// while a send is blocked inside the hook. Drive the table directly
    /// instead: a registerAndSend that starts after failAll must resume the
    /// continuation with sessionClosed without sending.
    func testPendingTableRegisterAfterFailAllResumesWithSessionClosed() async throws {
        let table = RclPendingCallTable()
        table.failAll(TransportError.sessionClosed)
        let sendRan = Box<Bool>(false)
        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let seq = table.registerAndSend(cont) {
                    sendRan.value = true
                    return 1
                }
                XCTAssertNil(seq, "registerAndSend after failAll must not return a sequence number")
            }
            XCTFail("expected sessionClosed")
        } catch let e as TransportError {
            guard case .sessionClosed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(sendRan.value, "send must not run once the table is closed")
        // And a late resolve for the never-registered sequence stays a no-op.
        XCTAssertFalse(table.resolve(seq: 1, with: .success(Data())))
    }

    func testClientCallAfterCloseThrowsSessionClosed() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        try serviceClient.close()
        do {
            _ = try await serviceClient.call(requestCDR: requestCDR, timeout: .seconds(1))
            XCTFail("expected sessionClosed")
        } catch let e as TransportError {
            guard case .sessionClosed = e else { return XCTFail("got \(e)") }
        }
    }

    func testCreateServiceClientDuringCloseDestroysAndThrows() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        client.onCreateServiceClient = { try? s.close() }
        XCTAssertThrowsError(
            try s.createServiceClient(
                name: "/add_two_ints", serviceTypeName: addTwoInts,
                requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        ) { error in
            guard case TransportError.notConnected = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(client.serviceClientsDestroyed.count, 1)
    }

    func testWaitForServiceReturnsWhenAvailable() async throws {
        let client = MockRclClient()
        client.serverAvailableValue = true
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        try await serviceClient.waitForService(timeout: .seconds(1))
    }

    func testWaitForServiceTimesOutWhenUnavailable() async throws {
        let client = MockRclClient()
        client.serverAvailableValue = false
        let s = try await openSession(client)
        let serviceClient = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        do {
            try await serviceClient.waitForService(timeout: .milliseconds(150))
            XCTFail("expected requestTimeout")
        } catch let e as TransportError {
            guard case .requestTimeout = e else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - Session teardown ordering

    func testSessionCloseDestroysServiceEntitiesBeforeSubscribersAndNodes() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        _ = try s.createSubscriber(
            topic: "/imu", typeName: "sensor_msgs/msg/Imu", typeHash: nil,
            qos: .sensorData, handler: { _, _ in })
        _ = try s.createServiceServer(
            name: "/set_bool", serviceTypeName: "std_srvs/srv/SetBool",
            requestTypeHash: nil, responseTypeHash: nil, qos: .default,
            handler: { _ in Data() })
        _ = try s.createServiceClient(
            name: "/add_two_ints", serviceTypeName: addTwoInts,
            requestTypeHash: nil, responseTypeHash: nil, qos: .default)
        try s.close()
        XCTAssertEqual(
            client.teardownEvents,
            [
                "client:/add_two_ints", "service:/set_bool", "subscription:/imu",
                "node:svc_node", "context",
            ])
    }
}
