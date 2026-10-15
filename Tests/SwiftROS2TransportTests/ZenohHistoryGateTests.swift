// ZenohHistoryGateTests.swift
// Ordering and de-duplication of a transient-local subscription's history.

import Foundation
import SwiftROS2TestSupport
import SwiftROS2Transport
import SwiftROS2Wire
import XCTest

final class ZenohHistoryGateTests: XCTestCase {
    private let codec = ZenohWireCodec(distro: .jazzy)
    private let gidA = [UInt8](repeating: 0xA1, count: 16)
    private let gidB = [UInt8](repeating: 0xB2, count: 16)

    private func sample(_ tag: UInt8, gid: [UInt8]? = nil, seq: Int64 = 0, ts: Int64 = 0) -> ZenohSample {
        ZenohSample(
            keyExpr: "0/tf_static/tf2_msgs::msg::dds_::TFMessage_/RIHS01_x",
            payload: Data([tag]),
            attachment: gid.map { codec.buildAttachment(seq: seq, tsNsec: ts, gid: $0) })
    }

    private func makeGate() -> (ZenohHistoryGate, Box<[UInt8]>) {
        let delivered = Box<[UInt8]>([])
        let gate = ZenohHistoryGate { delivered.value.append($0.payload[0]) }
        return (gate, delivered)
    }

    func testHistoryIsDeliveredBeforeLiveSamplesHeldDuringTheQuery() {
        let (gate, delivered) = makeGate()
        gate.receiveLive(sample(3, gid: gidA, seq: 3, ts: 300))
        gate.receiveHistory(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.receiveHistory(sample(2, gid: gidA, seq: 2, ts: 200))
        XCTAssertEqual(delivered.value, [], "nothing is delivered while the query runs")

        gate.finish()
        XCTAssertEqual(delivered.value, [1, 2, 3])

        gate.receiveLive(sample(4, gid: gidA, seq: 4, ts: 400))
        XCTAssertEqual(delivered.value, [1, 2, 3, 4])
    }

    func testALiveSampleAlsoFoundInTheHistoryIsDeliveredOnce() {
        let (gate, delivered) = makeGate()
        gate.receiveLive(sample(2, gid: gidA, seq: 2, ts: 200))
        gate.receiveHistory(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.receiveHistory(sample(2, gid: gidA, seq: 2, ts: 200))
        gate.finish()
        XCTAssertEqual(delivered.value, [1, 2])
    }

    func testTheSameSequenceNumberFromAnotherPublisherIsNotADuplicate() {
        let (gate, delivered) = makeGate()
        gate.receiveLive(sample(2, gid: gidB, seq: 1, ts: 200))
        gate.receiveHistory(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.finish()
        XCTAssertEqual(delivered.value, [1, 2])
    }

    func testHistoryFromSeveralPublishersIsOrderedBySourceTimestamp() {
        let (gate, delivered) = makeGate()
        gate.receiveHistory(sample(3, gid: gidB, seq: 7, ts: 300))
        gate.receiveHistory(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.receiveHistory(sample(2, gid: gidB, seq: 6, ts: 200))
        gate.finish()
        XCTAssertEqual(delivered.value, [1, 2, 3])
    }

    func testSamplesWithoutAnAttachmentKeepArrivalOrderAndAreNeverDropped() {
        let (gate, delivered) = makeGate()
        gate.receiveLive(sample(9))
        gate.receiveHistory(sample(5))
        gate.receiveHistory(sample(4))
        gate.finish()
        XCTAssertEqual(delivered.value, [5, 4, 9])
    }

    func testRepliesAfterTheEndAreDroppedAndFinishRunsOnce() {
        let (gate, delivered) = makeGate()
        gate.receiveHistory(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.finish()
        gate.receiveHistory(sample(2, gid: gidA, seq: 2, ts: 200))
        gate.finish()
        XCTAssertEqual(delivered.value, [1])
    }

    func testAQueryWithoutRepliesLetsLiveSamplesThrough() {
        let (gate, delivered) = makeGate()
        gate.receiveLive(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.finish()
        gate.receiveLive(sample(2, gid: gidA, seq: 2, ts: 200))
        XCTAssertEqual(delivered.value, [1, 2])
    }

    func testCloseDropsEverything() {
        let (gate, delivered) = makeGate()
        gate.receiveLive(sample(2, gid: gidA, seq: 2, ts: 200))
        gate.receiveHistory(sample(1, gid: gidA, seq: 1, ts: 100))
        gate.close()
        gate.finish()
        gate.receiveLive(sample(3, gid: gidA, seq: 3, ts: 300))
        XCTAssertEqual(delivered.value, [])
    }

    func testHeldLiveSamplesAreBounded() {
        let (gate, delivered) = makeGate()
        for i in 0..<(ZenohHistoryGate.maxHeldLiveSamples + 5) {
            gate.receiveLive(sample(UInt8(i % 256), gid: gidA, seq: Int64(i), ts: Int64(i)))
        }
        gate.finish()
        XCTAssertEqual(delivered.value.count, ZenohHistoryGate.maxHeldLiveSamples)
        XCTAssertEqual(delivered.value.first, 5, "the oldest held samples are dropped")
    }
}
