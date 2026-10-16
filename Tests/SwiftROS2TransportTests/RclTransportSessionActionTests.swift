import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2Transport

final class RclTransportSessionActionTests: XCTestCase {
    private let fibonacci = "example_interfaces/action/Fibonacci"
    private let requestId: [UInt8] = Array(0..<24)
    private let goalIdA: [UInt8] = Array(1...16)
    private let cdrHeader: [UInt8] = [0x00, 0x01, 0x00, 0x00]  // XCDR v1 little-endian
    private let goalIdB: [UInt8] = Array(17...32)
    private let noHashes = ActionRoleTypeHashes(
        sendGoalRequest: nil, sendGoalResponse: nil, cancelGoalRequest: nil,
        cancelGoalResponse: nil, getResultRequest: nil, getResultResponse: nil,
        feedbackMessage: nil, statusArray: nil)

    private func openSession(
        _ client: MockRclClient = MockRclClient(),
        registerNode: Bool = true
    ) async throws -> RclTransportSession {
        let s = RclTransportSession(client: client)
        try await s.open(config: .rcl(domainId: 0))
        if registerNode {
            try s.registerNode(name: "action_node", namespace: "/ios")
        }
        return s
    }

    private func makeHandlers(
        onSendGoal: @escaping @Sendable ([UInt8], Data) async throws -> (Bool, Int32, UInt32) = {
            _, _ in (true, 7, 9)
        },
        onCancelGoal: @escaping @Sendable (Data) async throws -> Data = { _ in Data() },
        onGetResult: @escaping @Sendable ([UInt8]) async throws -> GetResultAck = { _ in
            GetResultAck(status: 4, resultCDR: Data())
        }
    ) -> TransportActionServerHandlers {
        TransportActionServerHandlers(
            onSendGoal: onSendGoal, onCancelGoal: onCancelGoal, onGetResult: onGetResult)
    }

    // MARK: - Action server

    func testCreateActionServerRequiresNode() async throws {
        let s = try await openSession(registerNode: false)
        XCTAssertThrowsError(
            try s.createActionServer(
                name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
                qos: .default, handlers: makeHandlers())
        ) { error in
            guard case TransportError.subscriberCreationFailed = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreateActionServerRejectsEmptyNameAndType() async throws {
        let s = try await openSession()
        XCTAssertThrowsError(
            try s.createActionServer(
                name: "", actionTypeName: fibonacci, roleTypeHashes: noHashes,
                qos: .default, handlers: makeHandlers())
        ) { error in
            guard case TransportError.invalidConfiguration = error else {
                return XCTFail("got \(error)")
            }
        }
        XCTAssertThrowsError(
            try s.createActionServer(
                name: "/fibonacci", actionTypeName: "", roleTypeHashes: noHashes,
                qos: .default, handlers: makeHandlers())
        ) { error in
            guard case TransportError.invalidConfiguration = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreateActionServerAttachesToCurrentNodeAndPassesQoS() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let qos = TransportQoS(
            reliability: .bestEffort, durability: .transientLocal, history: .keepLast(5))
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: qos, handlers: makeHandlers())
        XCTAssertEqual(client.actionServersCreated.count, 1)
        XCTAssertEqual(client.actionServersCreated.first?.actionName, "/fibonacci")
        XCTAssertEqual(client.actionServersCreated.first?.actionTypeName, fibonacci)
        XCTAssertEqual(client.actionServersCreated.first?.qos, qos)
        XCTAssertTrue(client.actionServersCreated.first?.node === client.nodeHandles.first)
        XCTAssertEqual(server.name, "/fibonacci")
        XCTAssertTrue(server.isActive)
    }

    func testCreateActionServerSurfacesUnknownActionTypeError() async throws {
        let client = MockRclClient()
        client.createActionServerShouldThrow = .unsupportedFeature(
            "action type example_interfaces/action/Unknown has no bundled typesupport in the rcl backend")
        let s = try await openSession(client)
        XCTAssertThrowsError(
            try s.createActionServer(
                name: "/unknown", actionTypeName: "example_interfaces/action/Unknown",
                roleTypeHashes: noHashes, qos: .default, handlers: makeHandlers())
        ) { error in
            guard case TransportError.unsupportedFeature(let msg) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertTrue(msg.contains("example_interfaces/action/Unknown"))
        }
    }

    func testActionServerGoalAcceptFeedbackResultLifecycle() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        // The umbrella hands the result over as the whole response:
        // [header | status | pad (3) | int32 42].
        let resultBody = Data(cdrHeader + [0x04, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x00])
        let receivedGoal = Box<Data?>(nil)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default,
            handlers: makeHandlers(
                onSendGoal: { _, goalCDR in
                    receivedGoal.value = goalCDR
                    return (true, 7, 9)
                },
                onGetResult: { _ in GetResultAck(status: 4, resultCDR: resultBody) }
            ))
        let mockServer = client.actionServersCreated[0]

        // Goal request → accepted response with the handler's stamp; the goal
        // must be registered with rcl_action before the response goes out.
        // rmw_serialize hands over the goal frame with the body bare at the splice offset.
        let goalFrame = Data(cdrHeader + goalIdA + [0xAA, 0xBB])
        mockServer.fireGoalRequest(goalFrame, requestId: requestId)
        let responded = await eventually { mockServer.goalResponsesSent.count == 1 }
        XCTAssertTrue(responded, "goal response was not sent within the timeout")
        // The umbrella receives the goal behind exactly one header.
        XCTAssertEqual(receivedGoal.value.map { Array($0) }, cdrHeader + [0xAA, 0xBB])
        XCTAssertEqual(mockServer.goalResponsesSent.first?.requestId, requestId)
        let resp = try ActionFrameDecoder.decodeSendGoalResponse(
            from: mockServer.goalResponsesSent[0].data)
        XCTAssertTrue(resp.accepted)
        XCTAssertEqual(resp.stampSec, 7)
        XCTAssertEqual(resp.stampNanosec, 9)
        XCTAssertEqual(mockServer.acceptedGoals.count, 1)
        XCTAssertEqual(mockServer.acceptedGoals.first?.goalId, goalIdA)
        XCTAssertEqual(mockServer.acceptedGoals.first?.stampSec, 7)
        XCTAssertEqual(mockServer.acceptedGoals.first?.stampNanosec, 9)

        // Feedback rides the wire-path FeedbackMessage frame.
        let feedbackImpl = try XCTUnwrap(server as? PublishesActionFeedback)
        let fbCDR = Data(cdrHeader + [0x01, 0x02])  // umbrella-encoded (with header)
        try feedbackImpl.publishFeedback(goalId: goalIdA, feedbackCDR: fbCDR)
        // rmw_deserialize must see [header | uuid[16] | bare feedback] — no inner header.
        XCTAssertEqual(mockServer.feedbackPublished, [Data(cdrHeader + goalIdA + [0x01, 0x02])])

        // Executing snapshot → one EXECUTE event mirrored into rcl, then a
        // status publish from rcl's own tracking.
        try feedbackImpl.publishStatus(entries: [
            ActionStatusEntry(uuid: goalIdA, stampSec: 7, stampNanosec: 9, status: 2)
        ])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute])
        XCTAssertEqual(mockServer.statusPublishCount, 1)
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 0)

        // Terminal snapshot → SUCCEED event + notify-goal-done.
        try feedbackImpl.publishStatus(entries: [
            ActionStatusEntry(uuid: goalIdA, stampSec: 7, stampNanosec: 9, status: 4)
        ])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute, .succeed])
        XCTAssertEqual(mockServer.statusPublishCount, 2)
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 1)

        // Result request → GetResult response from the umbrella handler.
        mockServer.fireResultRequest(
            ActionFrameDecoder.encodeGetResultRequest(goalId: goalIdA), requestId: requestId)
        let resultSent = await eventually { mockServer.resultResponsesSent.count == 1 }
        XCTAssertTrue(resultSent, "result response was not sent within the timeout")
        XCTAssertEqual(mockServer.resultResponsesSent.first?.requestId, requestId)
        // [header | status | pad (3) | result] — one header, status stamped in.
        XCTAssertEqual(
            Array(mockServer.resultResponsesSent[0].data),
            cdrHeader + [0x04, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x00])
        let result = try ActionFrameDecoder.decodeGetResultResponse(
            from: mockServer.resultResponsesSent[0].data)
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.resultCDR, resultBody)
    }

    func testActionServerStatusSnapshotAcceptsUnseenGoalsBeforeStateSync() async throws {
        // The umbrella publishes its first status snapshot from inside
        // onSendGoal — before the transport's goal-response path ran
        // acceptGoal. The snapshot must register the goal with rcl first.
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        let mockServer = client.actionServersCreated[0]
        let feedbackImpl = try XCTUnwrap(server as? PublishesActionFeedback)

        try feedbackImpl.publishStatus(entries: [
            ActionStatusEntry(uuid: goalIdA, stampSec: 3, stampNanosec: 4, status: 2)
        ])
        XCTAssertEqual(mockServer.acceptedGoals.count, 1)
        XCTAssertEqual(mockServer.acceptedGoals.first?.goalId, goalIdA)
        XCTAssertEqual(mockServer.acceptedGoals.first?.stampSec, 3)
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute])
        XCTAssertEqual(mockServer.statusPublishCount, 1)
    }

    func testAcceptVsExecuteSnapshotRaceSerializesMirror() async throws {
        // The umbrella publishes an `accepted` snapshot from the goal-response
        // path while the executing Task publishes `executing` — concurrently.
        // The whole mirror step (map read, acceptGoal FFI, map write) must be
        // serialized: a racing `executing` snapshot must not observe the map
        // entry before the accept has landed in rcl and fire EXECUTE against
        // a goal rcl does not know yet (which would wedge rcl at ACCEPTED
        // forever). Drive the race deterministically by holding the first
        // acceptGoal FFI call open until the executing snapshot has been
        // attempted from another thread.
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        let mockServer = client.actionServersCreated[0]
        let feedbackImpl = try XCTUnwrap(server as? PublishesActionFeedback)

        let acceptEntered = DispatchSemaphore(value: 0)
        let releaseAccept = DispatchSemaphore(value: 0)
        client.onAcceptGoal = { [weak client] in
            client?.onAcceptGoal = nil  // hold only the first accept open
            acceptEntered.signal()
            releaseAccept.wait()
        }

        // Thread A: goal-response path → ensureAcceptedInRcl → acceptGoal
        // (now parked inside the FFI call, holding the mirror step).
        mockServer.fireGoalRequest(
            ActionFrameDecoder.encodeSendGoalRequest(goalId: goalIdA, goalCDR: Data()),
            requestId: requestId)
        XCTAssertEqual(
            acceptEntered.wait(timeout: .now() + 2), .success,
            "acceptGoal was not reached within the timeout")

        // Thread B: executing snapshot racing the in-flight accept. It must
        // block on the mirror step instead of replaying EXECUTE early.
        let statusDone = Box<Bool>(false)
        Thread.detachNewThread { [goalIdA] in
            try? feedbackImpl.publishStatus(entries: [
                ActionStatusEntry(uuid: goalIdA, stampSec: 7, stampNanosec: 9, status: 2)
            ])
            statusDone.value = true
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(statusDone.value, "executing snapshot overtook the in-flight accept")
        XCTAssertTrue(mockServer.goalStateUpdates.isEmpty)

        // Release the accept: the mirror must converge — accept first, then
        // exactly one EXECUTE transition. No lost transition, no early fire.
        releaseAccept.signal()
        let converged = await eventually { statusDone.value }
        XCTAssertTrue(converged, "executing snapshot did not complete within the timeout")
        XCTAssertEqual(mockServer.acceptedGoals.count, 1)
        XCTAssertEqual(mockServer.acceptedGoals.first?.goalId, goalIdA)
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute])
    }

    func testStatusSnapshotRetriesAcceptAfterFailure() async throws {
        // A failed acceptGoal must not commit the mirror entry — the next
        // snapshot retries the accept instead of desyncing permanently.
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        let mockServer = client.actionServersCreated[0]
        let feedbackImpl = try XCTUnwrap(server as? PublishesActionFeedback)
        let entry = ActionStatusEntry(uuid: goalIdA, stampSec: 3, stampNanosec: 4, status: 2)

        client.acceptGoalShouldThrow = .publishFailed("rcl says no")
        try feedbackImpl.publishStatus(entries: [entry])
        XCTAssertTrue(mockServer.acceptedGoals.isEmpty)
        XCTAssertTrue(mockServer.goalStateUpdates.isEmpty, "no events against an unaccepted goal")

        client.acceptGoalShouldThrow = nil
        try feedbackImpl.publishStatus(entries: [entry])
        XCTAssertEqual(mockServer.acceptedGoals.count, 1)
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute])
    }

    func testStatusSnapshotPartialChainAdvancesMirrorToReachedState() async throws {
        // A 1→4 snapshot replays [.execute, .succeed]. When .succeed fails,
        // the mirror must advance only to EXECUTING (the state rcl actually
        // reached) so the next snapshot replays just the missing .succeed —
        // and notify-goal-done must not fire for a goal that never reached a
        // terminal state in rcl.
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        let mockServer = client.actionServersCreated[0]
        let feedbackImpl = try XCTUnwrap(server as? PublishesActionFeedback)
        let succeeded = ActionStatusEntry(uuid: goalIdA, stampSec: 3, stampNanosec: 4, status: 4)

        client.updateGoalStateShouldThrowOn = [.succeed]
        try feedbackImpl.publishStatus(entries: [succeeded])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute])
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 0)

        client.updateGoalStateShouldThrowOn = []
        try feedbackImpl.publishStatus(entries: [succeeded])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute, .succeed])
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 1)
    }

    func testTerminalMirrorStateIsAbsorbing() async throws {
        // A stale CANCELING(3) snapshot racing past SUCCEEDED(4) must not
        // regress the mirror (which would re-replay .succeed and re-fire
        // notify-goal-done on the next SUCCEEDED snapshot).
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        let mockServer = client.actionServersCreated[0]
        let feedbackImpl = try XCTUnwrap(server as? PublishesActionFeedback)

        try feedbackImpl.publishStatus(entries: [
            ActionStatusEntry(uuid: goalIdA, stampSec: 3, stampNanosec: 4, status: 4)
        ])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute, .succeed])
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 1)

        // Stale non-terminal snapshot after the terminal one: absorbed.
        try feedbackImpl.publishStatus(entries: [
            ActionStatusEntry(uuid: goalIdA, stampSec: 3, stampNanosec: 4, status: 3)
        ])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute, .succeed])
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 1)

        // Repeated terminal snapshot: no event replay, no second notify.
        try feedbackImpl.publishStatus(entries: [
            ActionStatusEntry(uuid: goalIdA, stampSec: 3, stampNanosec: 4, status: 4)
        ])
        XCTAssertEqual(mockServer.goalStateUpdates.map { $0.event }, [.execute, .succeed])
        XCTAssertEqual(mockServer.notifyGoalDoneCount, 1)
    }

    func testActionServerGoalEventChains() {
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 1, to: 2), [.execute])
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 1, to: 4), [.execute, .succeed])
        XCTAssertEqual(
            RclTransportActionServer.goalEvents(from: 1, to: 5), [.cancelGoal, .canceled])
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 2, to: 3), [.cancelGoal])
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 3, to: 5), [.canceled])
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 2, to: 6), [.abort])
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 4, to: 4), [])
        XCTAssertEqual(RclTransportActionServer.goalEvents(from: 4, to: 2), [])
    }

    func testActionServerHandlerThrowsDropsResponse() async throws {
        // Mirrors the wire path: a throwing onSendGoal produces no reply.
        let client = MockRclClient()
        let s = try await openSession(client)
        let handlerRan = Box<Bool>(false)
        _ = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default,
            handlers: makeHandlers(onSendGoal: { _, _ in
                handlerRan.value = true
                throw TransportError.serviceHandlerFailed("boom")
            }))
        let mockServer = client.actionServersCreated[0]
        mockServer.fireGoalRequest(
            ActionFrameDecoder.encodeSendGoalRequest(goalId: goalIdA, goalCDR: Data()),
            requestId: requestId)
        let ran = await eventually { handlerRan.value }
        XCTAssertTrue(ran, "handler did not run within the timeout")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(mockServer.goalResponsesSent.isEmpty)
        XCTAssertTrue(mockServer.acceptedGoals.isEmpty)
    }

    func testActionServerCancelRoundTrip() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let cancelResponse = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let receivedRequests = Box<[Data]>([])
        _ = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default,
            handlers: makeHandlers(onCancelGoal: { req in
                receivedRequests.value.append(req)
                return cancelResponse
            }))
        let mockServer = client.actionServersCreated[0]
        let cancelRequest = Data([0x00, 0x01, 0x00, 0x00, 0x11, 0x22])
        mockServer.fireCancelRequest(cancelRequest, requestId: requestId)
        let responded = await eventually { mockServer.cancelResponsesSent.count == 1 }
        XCTAssertTrue(responded, "cancel response was not sent within the timeout")
        XCTAssertEqual(receivedRequests.value, [cancelRequest])
        XCTAssertEqual(mockServer.cancelResponsesSent.first?.data, cancelResponse)
        XCTAssertEqual(mockServer.cancelResponsesSent.first?.requestId, requestId)
    }

    func testActionServerCloseDestroysExactlyOnce() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let server = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        try server.close()
        try server.close()
        XCTAssertEqual(client.actionServersDestroyed.count, 1)
        XCTAssertFalse(server.isActive)
    }

    func testCreateActionServerDuringCloseDestroysAndThrows() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        client.onCreateActionServer = { try? s.close() }
        XCTAssertThrowsError(
            try s.createActionServer(
                name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
                qos: .default, handlers: makeHandlers())
        ) { error in
            guard case TransportError.notConnected = error else {
                return XCTFail("got \(error)")
            }
        }
        XCTAssertEqual(client.actionServersDestroyed.count, 1)
    }

    // MARK: - Action client

    func testCreateActionClientAttachesToCurrentNodeAndPassesQoS() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let qos = TransportQoS(
            reliability: .reliable, durability: .volatile, history: .keepLast(3))
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes, qos: qos)
        XCTAssertEqual(client.actionClientsCreated.count, 1)
        XCTAssertEqual(client.actionClientsCreated.first?.actionName, "/fibonacci")
        XCTAssertEqual(client.actionClientsCreated.first?.actionTypeName, fibonacci)
        XCTAssertEqual(client.actionClientsCreated.first?.qos, qos)
        XCTAssertTrue(client.actionClientsCreated.first?.node === client.nodeHandles.first)
        XCTAssertEqual(actionClient.name, "/fibonacci")
        XCTAssertTrue(actionClient.isActive)
    }

    func testClientSendGoalCorrelatesInterleavedGoals() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        // Resolve each goal request inline with a stamp derived from its
        // sequence number, so correlation mistakes surface as wrong stamps.
        client.onSendGoalRequest = { [weak client] seq, _ in
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: Int32(seq), stampNanosec: 0)
            client?.actionClientsCreated.first?.fireGoalResponse(
                sequenceNumber: seq, data: response)
        }
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)

        async let ackA = actionClient.sendGoal(
            goalId: goalIdA, goalCDR: Data([0x0A]), acceptanceTimeout: .seconds(2))
        async let ackB = actionClient.sendGoal(
            goalId: goalIdB, goalCDR: Data([0x0B]), acceptanceTimeout: .seconds(2))
        let (a, b) = try await (ackA, ackB)
        XCTAssertTrue(a.accepted)
        XCTAssertTrue(b.accepted)

        // Map each goal id to the sequence number its request carried and
        // check the resolved stamp matches that sequence number.
        let mockClient = client.actionClientsCreated[0]
        XCTAssertEqual(mockClient.goalRequestsSent.count, 2)
        let frameA = ActionFrameDecoder.encodeSendGoalRequest(
            goalId: goalIdA, goalCDR: Data([0x0A]))
        let seqA = try XCTUnwrap(mockClient.goalRequestsSent.first { $0.data == frameA }?.seq)
        let frameB = ActionFrameDecoder.encodeSendGoalRequest(
            goalId: goalIdB, goalCDR: Data([0x0B]))
        let seqB = try XCTUnwrap(mockClient.goalRequestsSent.first { $0.data == frameB }?.seq)
        XCTAssertEqual(a.stampSec, Int32(seqA))
        XCTAssertEqual(b.stampSec, Int32(seqB))
    }

    func testClientSendGoalRejectedFinishesStreams() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        client.onSendGoalRequest = { [weak client] seq, _ in
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: false, stampSec: 0, stampNanosec: 0)
            client?.actionClientsCreated.first?.fireGoalResponse(
                sequenceNumber: seq, data: response)
        }
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        let ack = try await actionClient.sendGoal(
            goalId: goalIdA, goalCDR: Data(), acceptanceTimeout: .seconds(2))
        XCTAssertFalse(ack.accepted)
        // Rejected goal: both streams are already finished.
        var feedbackFrames = 0
        for await _ in ack.feedback { feedbackFrames += 1 }
        XCTAssertEqual(feedbackFrames, 0)
        var statusUpdates = 0
        for await _ in ack.status { statusUpdates += 1 }
        XCTAssertEqual(statusUpdates, 0)
    }

    func testClientSendGoalSendFailureThrows() async throws {
        let client = MockRclClient()
        client.sendGoalRequestShouldThrow = .publishFailed("rcl says no")
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        do {
            _ = try await actionClient.sendGoal(
                goalId: goalIdA, goalCDR: Data(), acceptanceTimeout: .seconds(2))
            XCTFail("expected sendGoal to throw")
        } catch {
            guard case TransportError.publishFailed = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testClientFeedbackAndStatusRouteToGoalStreams() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        client.onSendGoalRequest = { [weak client] seq, _ in
            let response = ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 1, stampNanosec: 0)
            client?.actionClientsCreated.first?.fireGoalResponse(
                sequenceNumber: seq, data: response)
        }
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        let ack = try await actionClient.sendGoal(
            goalId: goalIdA, goalCDR: Data(), acceptanceTimeout: .seconds(2))
        XCTAssertTrue(ack.accepted)

        let mockClient = client.actionClientsCreated[0]
        // rmw_serialize hands over the feedback frame with the body bare.
        mockClient.fireFeedback(Data(cdrHeader + goalIdA + [0x05, 0x06]))
        // A feedback frame for an unrelated goal must not reach this stream.
        mockClient.fireFeedback(
            ActionFrameDecoder.encodeFeedbackMessage(goalId: goalIdB, feedbackCDR: Data([0xFF])))
        mockClient.fireStatus([
            RclGoalStatusRecord(goalId: goalIdA, stampSec: 1, stampNanosec: 0, status: 2)
        ])
        // Terminal status finishes both streams.
        mockClient.fireStatus([
            RclGoalStatusRecord(goalId: goalIdA, stampSec: 1, stampNanosec: 0, status: 4)
        ])

        var feedbackFrames: [Data] = []
        for await frame in ack.feedback { feedbackFrames.append(frame) }
        // The umbrella receives the feedback behind exactly one header.
        XCTAssertEqual(feedbackFrames, [Data(cdrHeader + [0x05, 0x06])])
        var statuses: [Int8] = []
        for await update in ack.status { statuses.append(update.status) }
        XCTAssertEqual(statuses, [2, 4])
    }

    func testClientGetResultRoundTrip() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        let resultBody = Data(cdrHeader + [0x04, 0x07])  // the whole response, as the umbrella decodes it
        let goalId = goalIdA
        async let ackAsync = actionClient.getResult(goalId: goalId, timeout: .seconds(2))
        let mockClient = client.actionClientsCreated[0]
        let sent = await eventually { mockClient.resultRequestsSent.count == 1 }
        XCTAssertTrue(sent, "result request was not sent within the timeout")
        XCTAssertEqual(
            mockClient.resultRequestsSent.first?.data,
            ActionFrameDecoder.encodeGetResultRequest(goalId: goalId))
        let seq = mockClient.resultRequestsSent[0].seq
        mockClient.fireResultResponse(
            sequenceNumber: seq,
            data: Data(cdrHeader + [0x04, 0x07]))  // status, then a 1-byte result
        let ack = try await ackAsync
        XCTAssertEqual(ack.status, 4)
        XCTAssertEqual(ack.resultCDR, resultBody)
    }

    /// Regression test for a crash: `ActionGoalHandle.result(timeout: nil)`
    /// substitutes `.seconds(Int.max)` for "no timeout" and threads it down
    /// to `getResult(goalId:timeout:)`. `rclAwaitCorrelatedReply`'s timeout
    /// race used to hand that value straight to `Task.sleep(for:)`, which
    /// converts `Duration` to nanoseconds internally and traps on overflow
    /// ("Not enough bits to represent the passed value") long before any
    /// reply could arrive. The response here is fired from a separate task
    /// after the request is observed sent (and a short extra delay), so this
    /// also proves `getResult` genuinely waits for it rather than returning
    /// early.
    func testClientGetResultWithHugeTimeoutDoesNotTrapAndWaitsForDelayedReply() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        let resultBody = Data(cdrHeader + [0x04, 0x07])  // umbrella-shaped: [header | status | result]
        let goalId = goalIdA
        async let ackAsync = actionClient.getResult(goalId: goalId, timeout: .seconds(Int.max))
        let mockClient = client.actionClientsCreated[0]
        let sent = await eventually { mockClient.resultRequestsSent.count == 1 }
        XCTAssertTrue(sent, "result request was not sent within the timeout")
        let seq = mockClient.resultRequestsSent[0].seq
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            mockClient.fireResultResponse(
                sequenceNumber: seq,
                data: ActionFrameDecoder.encodeGetResultResponse(status: 4, resultCDR: resultBody))
        }
        let ack = try await ackAsync
        XCTAssertEqual(ack.status, 4)
        XCTAssertEqual(ack.resultCDR, resultBody)
    }

    func testClientCancelGoalRoundTrip() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        let goalId = goalIdA
        async let ackAsync = actionClient.cancelGoal(
            goalId: goalId, beforeStampSec: nil, beforeStampNanosec: nil, timeout: .seconds(2))
        let mockClient = client.actionClientsCreated[0]
        let sent = await eventually { mockClient.cancelRequestsSent.count == 1 }
        XCTAssertTrue(sent, "cancel request was not sent within the timeout")

        // Expected CancelGoal_Request frame: header + uuid + zero stamp.
        var expectedRequest = Data([0x00, 0x01, 0x00, 0x00])
        expectedRequest.append(contentsOf: goalId)
        expectedRequest.append(contentsOf: [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(mockClient.cancelRequestsSent.first?.data, expectedRequest)

        // CancelGoal_Response: return_code 0, one goal canceling.
        var response = Data([0x00, 0x01, 0x00, 0x00])
        response.append(0)  // return_code = NONE
        response.append(contentsOf: [0, 0, 0])
        var count = UInt32(1).littleEndian
        withUnsafeBytes(of: &count) { response.append(contentsOf: $0) }
        response.append(contentsOf: goalId)
        var sec = Int32(11).littleEndian
        var nsec = UInt32(22).littleEndian
        withUnsafeBytes(of: &sec) { response.append(contentsOf: $0) }
        withUnsafeBytes(of: &nsec) { response.append(contentsOf: $0) }
        mockClient.fireCancelResponse(
            sequenceNumber: mockClient.cancelRequestsSent[0].seq, data: response)

        let ack = try await ackAsync
        XCTAssertEqual(ack.returnCode, 0)
        XCTAssertEqual(ack.goalsCanceling.count, 1)
        XCTAssertEqual(ack.goalsCanceling.first?.uuid, goalId)
        XCTAssertEqual(ack.goalsCanceling.first?.stampSec, 11)
        XCTAssertEqual(ack.goalsCanceling.first?.stampNanosec, 22)
    }

    func testCloseDuringPendingGoalResumesWithErrorExactlyOnce() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        let mockClient = client.actionClientsCreated[0]
        let resumeCount = Box<Int>(0)
        let errors = Box<[Error]>([])

        let goalTask = Task { [goalIdA] in
            do {
                _ = try await actionClient.sendGoal(
                    goalId: goalIdA, goalCDR: Data(), acceptanceTimeout: .seconds(10))
                resumeCount.value += 1
            } catch {
                resumeCount.value += 1
                errors.value.append(error)
            }
        }
        let sent = await eventually { mockClient.goalRequestsSent.count == 1 }
        XCTAssertTrue(sent, "goal request was not sent within the timeout")

        try actionClient.close()
        _ = await goalTask.value
        XCTAssertEqual(resumeCount.value, 1)
        XCTAssertEqual(errors.value.count, 1)
        guard case TransportError.sessionClosed = errors.value[0] else {
            return XCTFail("got \(errors.value[0])")
        }
        // A straggler response after close must not double-resume (the table
        // entry is gone) — give the Task hop a beat and re-check.
        mockClient.fireGoalResponse(
            sequenceNumber: mockClient.goalRequestsSent[0].seq,
            data: ActionFrameDecoder.encodeSendGoalResponse(
                accepted: true, stampSec: 0, stampNanosec: 0))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(resumeCount.value, 1)
        XCTAssertEqual(client.actionClientsDestroyed.count, 1)
    }

    func testClientSendGoalAfterCloseThrowsSessionClosed() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        try actionClient.close()
        try actionClient.close()  // double-close is a no-op
        XCTAssertEqual(client.actionClientsDestroyed.count, 1)
        do {
            _ = try await actionClient.sendGoal(
                goalId: goalIdA, goalCDR: Data(), acceptanceTimeout: .seconds(1))
            XCTFail("expected sendGoal to throw")
        } catch {
            guard case TransportError.sessionClosed = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testWaitForActionServerReturnsWhenAvailable() async throws {
        let client = MockRclClient()
        client.actionServerAvailableValue = true
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        try await actionClient.waitForActionServer(timeout: .seconds(2))
    }

    func testWaitForActionServerTimesOutWhenUnavailable() async throws {
        let client = MockRclClient()
        client.actionServerAvailableValue = false
        let s = try await openSession(client)
        let actionClient = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        do {
            try await actionClient.waitForActionServer(timeout: .milliseconds(200))
            XCTFail("expected waitForActionServer to throw")
        } catch {
            guard case TransportError.actionServerUnavailable = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    func testCreateActionClientDuringCloseDestroysAndThrows() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        client.onCreateActionClient = { try? s.close() }
        XCTAssertThrowsError(
            try s.createActionClient(
                name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
                qos: .default)
        ) { error in
            guard case TransportError.notConnected = error else {
                return XCTFail("got \(error)")
            }
        }
        XCTAssertEqual(client.actionClientsDestroyed.count, 1)
    }

    func testSessionCloseDestroysActionEntitiesBeforeServiceEntities() async throws {
        let client = MockRclClient()
        let s = try await openSession(client)
        _ = try s.createActionServer(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default, handlers: makeHandlers())
        _ = try s.createActionClient(
            name: "/fibonacci", actionTypeName: fibonacci, roleTypeHashes: noHashes,
            qos: .default)
        _ = try s.createServiceServer(
            name: "/set_bool", serviceTypeName: "std_srvs/srv/SetBool",
            requestTypeHash: nil, responseTypeHash: nil, qos: .default,
            handler: { _ in Data() })
        try s.close()
        XCTAssertEqual(
            client.teardownEvents,
            [
                "actionClient:/fibonacci", "actionServer:/fibonacci", "service:/set_bool",
                "node:action_node", "context",
            ])
    }
}
