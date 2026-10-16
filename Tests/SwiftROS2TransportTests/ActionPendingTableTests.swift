// ActionPendingTableTests.swift
// Behavior tests for the action-side correlation actor.

import Foundation
import XCTest

@testable import SwiftROS2Transport

final class ActionPendingTableTests: XCTestCase {
    private func makeGoalId(_ b: UInt8) -> [UInt8] {
        return Array(repeating: b, count: 16)
    }

    func testYieldFeedbackToRegisteredStream() async throws {
        let table = ActionPendingTable()
        let id = makeGoalId(0xAA)
        var fbCont: AsyncStream<Data>.Continuation!
        let fb = AsyncStream<Data> { fbCont = $0 }
        var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let st = AsyncStream<ActionStatusUpdate> { stCont = $0 }

        await table.registerStreams(goalId: id, feedback: fbCont, status: stCont)

        let yielded = await table.yieldFeedback(goalId: id, cdr: Data([0x42]))
        XCTAssertTrue(yielded)
        // Force completion so the iteration terminates.
        await table.cancel(goalId: id)

        var seen: [Data] = []
        for await frame in fb {
            seen.append(frame)
        }
        XCTAssertEqual(seen, [Data([0x42])])

        // Status stream is also finished by cancel().
        var statusSeen: [Int8] = []
        for await s in st {
            statusSeen.append(s.status)
        }
        XCTAssertTrue(statusSeen.isEmpty)
    }

    func testYieldFeedbackUnknownGoalIsNoOp() async {
        let table = ActionPendingTable()
        let yielded = await table.yieldFeedback(goalId: makeGoalId(0x01), cdr: Data())
        XCTAssertFalse(yielded)
    }

    func testTerminalStatusFinishesStreams() async throws {
        let table = ActionPendingTable()
        let id = makeGoalId(0xBB)
        var fbCont: AsyncStream<Data>.Continuation!
        let fb = AsyncStream<Data> { fbCont = $0 }
        var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let st = AsyncStream<ActionStatusUpdate> { stCont = $0 }

        await table.registerStreams(goalId: id, feedback: fbCont, status: stCont)

        // STATUS_EXECUTING — non-terminal, streams stay open.
        await table.yieldStatus(goalId: id, status: 2)
        // STATUS_SUCCEEDED — terminal, streams close.
        await table.yieldStatus(goalId: id, status: 4)

        var statusValues: [Int8] = []
        for await s in st {
            statusValues.append(s.status)
        }
        XCTAssertEqual(statusValues, [2, 4])

        var fbValues: [Data] = []
        for await frame in fb {
            fbValues.append(frame)
        }
        XCTAssertTrue(fbValues.isEmpty)
    }

    func testCancelFinishesStreamsAndDropsTheGoal() async {
        let table = ActionPendingTable()
        let id = makeGoalId(0xEE)
        var fbCont: AsyncStream<Data>.Continuation!
        let fb = AsyncStream<Data> { fbCont = $0 }
        var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
        let st = AsyncStream<ActionStatusUpdate> { stCont = $0 }
        await table.registerStreams(goalId: id, feedback: fbCont, status: stCont)

        let known = await table.cancel(goalId: id)
        XCTAssertTrue(known)
        for await _ in fb { XCTFail("feedback after cancel") }
        for await _ in st { XCTFail("status after cancel") }
        let count = await table.count
        XCTAssertEqual(count, 0)
        let again = await table.cancel(goalId: id)
        XCTAssertFalse(again)
    }

    func testFinishAllFinishesEveryGoal() async {
        let table = ActionPendingTable()
        var streams: [AsyncStream<Data>] = []
        for b: UInt8 in [0x01, 0x02] {
            var fbCont: AsyncStream<Data>.Continuation!
            streams.append(AsyncStream<Data> { fbCont = $0 })
            var stCont: AsyncStream<ActionStatusUpdate>.Continuation!
            _ = AsyncStream<ActionStatusUpdate> { stCont = $0 }
            await table.registerStreams(goalId: makeGoalId(b), feedback: fbCont, status: stCont)
        }

        await table.finishAll()

        for stream in streams {
            for await _ in stream { XCTFail("feedback after finishAll") }
        }
        let count = await table.count
        XCTAssertEqual(count, 0)
    }
}
