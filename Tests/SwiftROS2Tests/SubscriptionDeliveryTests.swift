import Foundation
import SwiftROS2TestSupport
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

/// `SubscriptionDelivery` and the `handler:` overload, driven through `MockTransportSession`.
///
/// The mock subscriber's handler stands in for the transport's receive thread: the test calls it
/// with raw CDR payloads and observes what the subscription decodes and hands to the user.
final class SubscriptionDeliveryTests: XCTestCase {
    // MARK: - .latestOnly

    func testBurstWhileTheHandlerIsBlockedDeliversTheFirstAndTheNewestOnly() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { message in
            delivered.append(message.seq)
            if message.seq == 0 {
                entered.signal()
                gate.wait()
            }
        }
        let feed = session.subscribers[0].handler

        feed(SeqMsg(tag: tag, seq: 0).cdr, 0)
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)

        // The handler is blocked: every feed only swaps the slot and returns at once.
        var slowest: TimeInterval = 0
        for seq in UInt32(1)...200 {
            let start = Date()
            feed(SeqMsg(tag: tag, seq: seq).cdr, 0)
            slowest = max(slowest, Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(slowest, 0.5, "a feed waited on the blocked handler")
        gate.signal()

        await waitUntil { delivered.value.last == 200 }
        XCTAssertEqual(delivered.value, [0, 200])
        // The superseded payloads were never decoded.
        XCTAssertEqual(DecodeLog.shared.decoded(tag), [0, 200])
        sub.cancel()
    }

    func testHandlerRunsSeriallyAndInArrivalOrder() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let inFlight = Box(0)
        let maxInFlight = Box(0)
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { message in
            inFlight.mutate { $0 += 1 }
            maxInFlight.mutate { $0 = max($0, inFlight.value) }
            delivered.append(message.seq)
            if message.seq % 7 == 0 { Thread.sleep(forTimeInterval: 0.001) }
            inFlight.mutate { $0 -= 1 }
        }
        let feed = session.subscribers[0].handler

        // Several feeding threads, each feeding increasing sequence numbers. Per thread, the
        // handler must see them strictly increasing, and never two calls at once.
        let threads = 4
        let perThread: UInt32 = 300
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                feed(SeqMsg(tag: tag, seq: UInt32(t) * 10_000 + i).cdr, 0)
            }
        }
        // A sentinel fed after every thread finished is the newest message, so it is delivered last.
        let sentinel: UInt32 = 99_999
        feed(SeqMsg(tag: tag, seq: sentinel).cdr, 0)
        await waitUntil { delivered.value.last == sentinel }

        XCTAssertEqual(maxInFlight.value, 1)
        for t in 0..<threads {
            let base = UInt32(t) * 10_000
            let mine = delivered.value.filter { $0 >= base && $0 < base + 10_000 }
            XCTAssertEqual(mine, mine.sorted(), "thread \(t) delivered out of order")
            XCTAssertEqual(Set(mine).count, mine.count, "thread \(t) delivered a message twice")
        }
        sub.cancel()
    }

    func testSingleFeederSeesStrictlyIncreasingSequenceAndTheLastMessage() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { message in
            delivered.append(message.seq)
            Thread.sleep(forTimeInterval: 0.002)
        }
        let feed = session.subscribers[0].handler
        for seq in UInt32(0)..<500 {
            feed(SeqMsg(tag: tag, seq: seq).cdr, 0)
        }
        await waitUntil { delivered.value.last == 499 }
        let seen = delivered.value
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(Set(seen).count, seen.count)
        XCTAssertLessThan(seen.count, 500, "nothing was coalesced")
        sub.cancel()
    }

    func testMessagesStreamIsFinishedAtCreation() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly)
        session.subscribers[0].handler(SeqMsg(tag: tag, seq: 1).cdr, 0)

        var count = 0
        for await _ in sub.messages { count += 1 }
        XCTAssertEqual(count, 0)
        sub.cancel()
    }

    func testLatestOnlyReaderKeepsOneSampleAndPassesReliabilityAndDurabilityThrough() async throws {
        let (node, session) = try await makeNode()
        let latest = try await node.createSubscription(
            SeqMsg.self, topic: "latched", qos: .latched, delivery: .latestOnly)
        let deep = try await node.createSubscription(
            SeqMsg.self, topic: "deep",
            qos: QoSProfile(reliability: .reliable, durability: .transientLocal, history: .keepAll),
            delivery: .latestOnly)
        let stream = try await node.createSubscription(
            SeqMsg.self, topic: "stream", qos: .reliableSensor, delivery: .stream)

        let qos = session.subscribers.map(\.qos)
        XCTAssertEqual(qos[0], TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1)))
        XCTAssertEqual(qos[1], TransportQoS(reliability: .reliable, durability: .transientLocal, history: .keepLast(1)))
        XCTAssertEqual(qos[2], TransportQoS(reliability: .reliable, durability: .volatile, history: .keepLast(10)))
        latest.cancel()
        deep.cancel()
        stream.cancel()
    }

    func testOnMessageAfterABurstDeliversOnlyTheNewest() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly)
        for seq in UInt32(1)...10 {
            session.subscribers[0].handler(SeqMsg(tag: tag, seq: seq).cdr, 0)
        }
        // Nothing is decoded while no handler is attached.
        XCTAssertEqual(DecodeLog.shared.decoded(tag), [])

        let delivered = Box<[UInt32]>([])
        sub.onMessage { delivered.append($0.seq) }
        await waitUntil { delivered.value == [10] }

        session.subscribers[0].handler(SeqMsg(tag: tag, seq: 11).cdr, 0)
        await waitUntil { delivered.value == [10, 11] }
        XCTAssertEqual(DecodeLog.shared.decoded(tag), [10, 11])
        sub.cancel()
    }

    func testOnMessageReplacesTheHandler() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let first = Box<[UInt32]>([])
        let second = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { first.append($0.seq) }
        session.subscribers[0].handler(SeqMsg(tag: tag, seq: 1).cdr, 0)
        await waitUntil { first.value == [1] }

        sub.onMessage { second.append($0.seq) }
        session.subscribers[0].handler(SeqMsg(tag: tag, seq: 2).cdr, 0)
        await waitUntil { second.value == [2] }
        XCTAssertEqual(first.value, [1])
        sub.cancel()
    }

    // MARK: - Handler at creation

    func testSampleDeliveredDuringCreateSubscriberReachesTheLatestOnlyHandler() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        session.onCreateSubscriber = { handler in
            handler(SeqMsg(tag: tag, seq: 42).cdr, 0)
        }
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .latched, delivery: .latestOnly
        ) { delivered.append($0.seq) }
        await waitUntil { delivered.value == [42] }
        sub.cancel()
    }

    func testSampleDeliveredDuringCreateSubscriberReachesTheStreamHandler() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        session.onCreateSubscriber = { handler in
            handler(SeqMsg(tag: tag, seq: 7).cdr, 0)
        }
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .latched, delivery: .stream
        ) { delivered.append($0.seq) }
        // `.stream` calls the handler inline, so it already ran inside createSubscriber.
        XCTAssertEqual(delivered.value, [7])
        sub.cancel()
    }

    // MARK: - cancel()

    func testCancelFromInsideTheHandlerReturnsAndStopsDelivery() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let subscription = Box<ROS2Subscription<SeqMsg>?>(nil)
        let delivered = Box<[UInt32]>([])
        let cancelled = Box(false)
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { message in
            delivered.append(message.seq)
            subscription.value?.cancel()
            cancelled.value = true
        }
        subscription.value = sub
        let feed = session.subscribers[0].handler

        feed(SeqMsg(tag: tag, seq: 1).cdr, 0)
        await waitUntil { cancelled.value }
        XCTAssertFalse(session.subscribers[0].isActive, "cancel() did not close the transport subscriber")

        for seq in UInt32(2)...20 {
            feed(SeqMsg(tag: tag, seq: seq).cdr, 0)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(delivered.value, [1])
    }

    func testAtMostOneHandlerCallStartsAfterCancelReturns() async throws {
        for round in 0..<20 {
            let tag = UUID().uuidString
            let (node, session) = try await makeNode()
            let calls = Box(0)
            let sub = try await node.createSubscription(
                SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
            ) { _ in
                calls.mutate { $0 += 1 }
            }
            let feed = session.subscribers[0].handler
            let stop = Box(false)
            let feeder = Thread {
                var seq: UInt32 = 0
                while !stop.value {
                    feed(SeqMsg(tag: tag, seq: seq).cdr, 0)
                    seq &+= 1
                }
            }
            feeder.start()
            await waitUntil { calls.value >= 3 }

            sub.cancel()
            let atCancel = calls.value
            try await Task.sleep(nanoseconds: 20_000_000)
            stop.value = true
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertLessThanOrEqual(calls.value - atCancel, 1, "round \(round)")
        }
    }

    func testCancelEmptiesTheSlot() async throws {
        let (node, session) = try await makeNode()
        let live = LiveCounter()
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly)
        session.subscribers[0].handler(live.payload(SeqMsg(tag: UUID().uuidString, seq: 1)), 0)
        XCTAssertEqual(live.count, 1)
        sub.cancel()
        XCTAssertEqual(live.count, 0)
    }

    // MARK: - Memory bound

    func testNeverMoreThanTwoPayloadsAreAlive() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let live = LiveCounter()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { message in
            delivered.append(message.seq)
            if message.seq == 0 {
                entered.signal()
                gate.wait()
            }
        }
        let feed = session.subscribers[0].handler

        feed(live.payload(SeqMsg(tag: tag, seq: 0)), 0)
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        var highest = 0
        for seq in UInt32(1)...100 {
            feed(live.payload(SeqMsg(tag: tag, seq: seq)), 0)
            highest = max(highest, live.count)
        }
        gate.signal()
        // Keep feeding while the drain runs.
        for seq in UInt32(101)...300 {
            feed(live.payload(SeqMsg(tag: tag, seq: seq)), 0)
            highest = max(highest, live.count)
        }
        await waitUntil { delivered.value.last == 300 }
        // Between feeds the subscription holds at most two: one waiting in the slot and one being
        // decoded or handled.
        XCTAssertLessThanOrEqual(highest, 2)
        // At any instant, counted when each payload is created, there is at most one more: the
        // payload arriving from the transport, which briefly overlaps the one it replaces.
        XCTAssertLessThanOrEqual(live.highWaterMark, 3)
        await waitUntil { live.count == 0 }
        sub.cancel()
    }

    // MARK: - Decode failures

    func testDecodeFailuresAreCountedAndDeliveryGoesOn() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .latestOnly
        ) { delivered.append($0.seq) }
        let feed = session.subscribers[0].handler

        feed(Data([0x00, 0x01]), 0)
        await waitUntil { sub.decodeFailureCount == 1 }
        feed(SeqMsg(tag: tag, seq: 5).cdr, 0)
        await waitUntil { delivered.value == [5] }
        XCTAssertEqual(sub.decodeFailureCount, 1)
        sub.cancel()
    }

    // MARK: - .stream

    func testStreamWithAHandlerStillBuffersTheNewestHundredMessages() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let delivered = Box<[UInt32]>([])
        let sub = try await node.createSubscription(
            SeqMsg.self, topic: "seq", qos: .sensorData, delivery: .stream
        ) { delivered.append($0.seq) }
        for seq in UInt32(1)...150 {
            session.subscribers[0].handler(SeqMsg(tag: tag, seq: seq).cdr, 0)
        }
        // The handler ran on the feeding thread, once per message.
        XCTAssertEqual(delivered.value, Array(1...150))
        XCTAssertEqual(DecodeLog.shared.decoded(tag).count, 150)

        sub.cancel()
        var buffered: [UInt32] = []
        for await message in sub.messages { buffered.append(message.seq) }
        XCTAssertEqual(buffered, Array(51...150))
    }

    func testCreateSubscriptionWithoutDeliveryKeepsTheStreamBehavior() async throws {
        let tag = UUID().uuidString
        let (node, session) = try await makeNode()
        let sub = try await node.createSubscription(SeqMsg.self, topic: "seq")
        XCTAssertEqual(session.subscribers[0].qos.history, .keepLast(10))
        session.subscribers[0].handler(SeqMsg(tag: tag, seq: 3).cdr, 0)
        var iterator = sub.messages.makeAsyncIterator()
        let message = await iterator.next()
        XCTAssertEqual(message?.seq, 3)
        sub.cancel()
    }

    // MARK: - Helpers

    private func makeNode() async throws -> (ROS2Node, MockTransportSession) {
        let session = MockTransportSession()
        session.installEchoServiceTransport()
        let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/mock:7447"), session: session)
        return (try await ctx.createNode(name: "n", namespace: "/ns"), session)
    }
}

/// A test message that records every decode under its tag, so a test can tell which payloads
/// the subscription decoded.
struct SeqMsg: ROS2Message, Equatable {
    static let typeInfo = ROS2MessageTypeInfo(typeName: "swift_ros2_test/msg/Seq")

    var tag: String
    var seq: UInt32

    init(tag: String, seq: UInt32) {
        self.tag = tag
        self.seq = seq
    }

    func encode(to encoder: CDREncoder) throws {
        encoder.writeString(tag)
        encoder.writeUInt32(seq)
    }

    init(from decoder: CDRDecoder) throws {
        self.tag = try decoder.readString()
        self.seq = try decoder.readUInt32()
        DecodeLog.shared.record(tag: tag, seq: seq)
    }

    /// The message as a CDR payload with its encapsulation header.
    var cdr: Data {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try! encode(to: encoder)
        return encoder.getData()
    }
}

/// Every `SeqMsg` decode, by tag. Tests use a fresh tag each, so they can run in parallel.
final class DecodeLog: @unchecked Sendable {
    static let shared = DecodeLog()

    private let lock = NSLock()
    private var byTag: [String: [UInt32]] = [:]

    func record(tag: String, seq: UInt32) {
        lock.lock()
        byTag[tag, default: []].append(seq)
        lock.unlock()
    }

    func decoded(_ tag: String) -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return byTag[tag] ?? []
    }
}

/// Counts the payloads whose bytes are still allocated: each payload frees its buffer, and
/// lowers the count, when the last `Data` that refers to it goes away. ``highWaterMark`` is the
/// largest count ever reached, recorded as each payload is created, so a transient overlap that
/// is gone by the time a caller samples ``count`` is still seen.
final class LiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var live = 0
    private var peak = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return live
    }

    var highWaterMark: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func payload(_ message: SeqMsg) -> Data {
        let bytes = message.cdr
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 8)
        bytes.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        lock.lock()
        live += 1
        peak = max(peak, live)
        lock.unlock()
        return Data(
            bytesNoCopy: pointer, count: bytes.count,
            deallocator: .custom { [self] pointer, _ in
                pointer.deallocate()
                lock.lock()
                live -= 1
                lock.unlock()
            })
    }
}
