// TransportActionStubTests.swift
// Phase 3: verify the new TransportError cases compile and carry the expected payload.

import Foundation
import XCTest

@testable import SwiftROS2Transport

final class TransportActionStubTests: XCTestCase {
    func testActionErrorDescriptions() {
        XCTAssertEqual(
            TransportError.goalRejected.errorDescription,
            "Action goal was rejected by the server"
        )
        XCTAssertEqual(
            TransportError.goalUnknown.errorDescription,
            "Action goal id is unknown to the server"
        )
        XCTAssertEqual(
            TransportError.actionServerUnavailable.errorDescription,
            "Action server is not reachable"
        )
    }

    func testActionErrorIsRecoverable() {
        // Non-recoverable: server made a definitive decision.
        XCTAssertFalse(TransportError.goalRejected.isRecoverable)
        XCTAssertFalse(TransportError.goalUnknown.isRecoverable)
        // Recoverable: discovery may succeed later.
        XCTAssertTrue(TransportError.actionServerUnavailable.isRecoverable)
    }

    // MARK: - Ack struct shape

    func testSendGoalAckHoldsAcceptedFlagAndStreams() async {
        var feedbackCont: AsyncStream<Data>.Continuation!
        let feedback = AsyncStream<Data> { feedbackCont = $0 }
        var statusCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let status = AsyncStream<ActionStatusUpdate> { statusCont = $0 }

        let ack = SendGoalAck(
            accepted: true,
            stampSec: 100,
            stampNanosec: 200,
            feedback: feedback,
            status: status
        )
        XCTAssertTrue(ack.accepted)
        XCTAssertEqual(ack.stampSec, 100)
        XCTAssertEqual(ack.stampNanosec, 200)

        // Streams are usable. Yield + finish, then drain inline so failures
        // surface in this test rather than vanishing into a detached Task.
        feedbackCont.yield(Data([0x42]))
        feedbackCont.finish()
        statusCont.yield(ActionStatusUpdate(status: 1))
        statusCont.finish()

        var feedbackSeen: [Data] = []
        for await fb in ack.feedback { feedbackSeen.append(fb) }
        XCTAssertEqual(feedbackSeen, [Data([0x42])])

        var statusSeen: [Int8] = []
        for await st in ack.status { statusSeen.append(st.status) }
        XCTAssertEqual(statusSeen, [1])
    }

    func testGetResultAckCarriesStatusAndCDR() {
        let ack = GetResultAck(status: 4, resultCDR: Data([0x00, 0x01, 0x02]))
        XCTAssertEqual(ack.status, 4)
        XCTAssertEqual(ack.resultCDR, Data([0x00, 0x01, 0x02]))
    }

    func testCancelGoalAckCarriesReturnCodeAndList() {
        let goal0 = (uuid: [UInt8](repeating: 0xAB, count: 16), stampSec: Int32(1), stampNanosec: UInt32(2))
        let ack = CancelGoalAck(returnCode: 0, goalsCanceling: [goal0])
        XCTAssertEqual(ack.returnCode, 0)
        XCTAssertEqual(ack.goalsCanceling.count, 1)
        XCTAssertEqual(ack.goalsCanceling[0].uuid.count, 16)
    }

    // MARK: - TransportSession default impl throws unsupportedFeature

    func testDefaultCreateActionServerThrowsUnsupported() async throws {
        let session: any TransportSession = StubSessionForActionDefaults()
        let qos = TransportQoS.default
        let hashes = ActionRoleTypeHashes(
            sendGoalRequest: nil, sendGoalResponse: nil,
            cancelGoalRequest: nil, cancelGoalResponse: nil,
            getResultRequest: nil, getResultResponse: nil,
            feedbackMessage: nil, statusArray: nil
        )
        let handlers = TransportActionServerHandlers(
            onSendGoal: { _, _ in (true, 0, 0) },
            onCancelGoal: { _ in Data() },
            onGetResult: { _ in GetResultAck(status: 4, resultCDR: Data()) }
        )
        do {
            _ = try session.createActionServer(
                name: "/x",
                actionTypeName: "ex/action/Foo",
                roleTypeHashes: hashes,
                qos: qos,
                handlers: handlers
            )
            XCTFail("expected unsupportedFeature")
        } catch let err as TransportError {
            if case .unsupportedFeature = err { return }
            XCTFail("got \(err) instead of unsupportedFeature")
        }
    }

    func testDefaultCreateActionClientThrowsUnsupported() async throws {
        let session: any TransportSession = StubSessionForActionDefaults()
        let qos = TransportQoS.default
        let hashes = ActionRoleTypeHashes(
            sendGoalRequest: nil, sendGoalResponse: nil,
            cancelGoalRequest: nil, cancelGoalResponse: nil,
            getResultRequest: nil, getResultResponse: nil,
            feedbackMessage: nil, statusArray: nil
        )
        do {
            _ = try session.createActionClient(
                name: "/x",
                actionTypeName: "ex/action/Foo",
                roleTypeHashes: hashes,
                qos: qos
            )
            XCTFail("expected unsupportedFeature")
        } catch let err as TransportError {
            if case .unsupportedFeature = err { return }
            XCTFail("got \(err) instead of unsupportedFeature")
        }
    }
}

// Bare-minimum TransportSession for the default-impl test — overrides only
// the lifecycle bits the harness needs and inherits the action methods from
// the protocol extension.
private final class StubSessionForActionDefaults: TransportSession, @unchecked Sendable {
    var isConnected: Bool { false }
    var transportType: TransportType { .zenoh }
    var sessionId: String { "stub" }

    func open(config: TransportConfig) async throws {}
    func close() throws {}

    func createPublisher(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS
    ) throws -> any TransportPublisher {
        throw TransportError.unsupportedFeature("publisher")
    }
    func createSubscriber(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        throw TransportError.unsupportedFeature("subscriber")
    }
    func createServiceServer(
        name: String, serviceTypeName: String,
        requestTypeHash: String?, responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        throw TransportError.unsupportedFeature("service server")
    }
    func createServiceClient(
        name: String, serviceTypeName: String,
        requestTypeHash: String?, responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient {
        throw TransportError.unsupportedFeature("service client")
    }
}
