import Foundation
import SwiftROS2Transport

/// In-memory DDSClientProtocol used by DDSTransportSession unit tests.
final class MockDDSClient: DDSClientProtocol, @unchecked Sendable {
    private let lock = NSLock()

    // Configurable behavior
    var isAvailable = true
    var sessionConnected = false
    var sessionIdValue: String? = "mock-dds-session"

    // Recorded invocations
    private(set) var sessionCreations: [(domainId: Int32, config: DDSBridgeDiscoveryConfig)] = []
    private(set) var sessionDestructions = 0
    private(set) var writers: [(topic: String, type: String, qos: DDSBridgeQoSConfig, userData: String?)] = []
    private(set) var writes: [(topic: String, data: Data, timestamp: UInt64)] = []
    private(set) var destroyedWriters = 0
    private(set) var readers:
        [(topic: String, type: String, qos: DDSBridgeQoSConfig, userData: String?, handler: (Data, UInt64) -> Void)] =
            []
    private(set) var destroyedReaders = 0

    // Publication-match override (per topic). Used to drive `waitForService`.
    private var matchedTopics: Set<String> = []

    // Pending `awaitWrite` callers waiting for the next write to a topic.
    // Resumed eagerly from `writeRawCDR` so the test does not have to wait
    // for the next 5 ms poll tick.
    private var writeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Test hook: closure invoked on every `writeRawCDR` to a request-style
    /// topic (suffix matching is the caller's job). If it returns non-nil
    /// bytes, the mock synchronously delivers those bytes to readers on the
    /// matching reply topic — a quick way to wire up service / action
    /// request-reply round-trips without a real DDS bus.
    var serviceReplyHandler: (@Sendable (_ requestTopic: String, _ requestData: Data) -> Data?)?

    /// Test helper: per-topic capture of every `writeRawCDR` payload.
    var writesByTopic: [String: [Data]] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: [Data]] = [:]
        for w in writes {
            out[w.topic, default: []].append(w.data)
        }
        return out
    }

    func createSession(domainId: Int32, discoveryConfig: DDSBridgeDiscoveryConfig) throws {
        lock.lock()
        defer { lock.unlock() }
        sessionCreations.append((domainId, discoveryConfig))
        sessionConnected = true
    }

    func destroySession() throws {
        lock.lock()
        defer { lock.unlock() }
        sessionDestructions += 1
        sessionConnected = false
    }

    func isConnected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionConnected
    }

    func getSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionIdValue
    }

    func createRawWriter(
        topicName: String, typeName: String,
        qos: DDSBridgeQoSConfig, userData: String?
    ) throws -> any DDSWriterHandle {
        lock.lock()
        defer { lock.unlock() }
        let handle = MockDDSWriterHandle(topic: topicName)
        writers.append((topicName, typeName, qos, userData))
        return handle
    }

    func writeRawCDR(writer: any DDSWriterHandle, data: Data, timestamp: UInt64) throws {
        let waitersToWake: [CheckedContinuation<Void, Never>]
        let topic: String
        let replyHandler: (@Sendable (String, Data) -> Data?)?
        do {
            lock.lock()
            defer { lock.unlock() }
            topic = (writer as? MockDDSWriterHandle)?.topic ?? "<unknown>"
            writes.append((topic, data, timestamp))
            waitersToWake = writeWaiters.removeValue(forKey: topic) ?? []
            replyHandler = serviceReplyHandler
        }
        for waiter in waitersToWake { waiter.resume() }

        // If a reply handler is registered and the write landed on a request
        // topic, invoke it and route any returned reply bytes to the matching
        // reply topic's readers. The reply-topic mapping mirrors what
        // `DDSWireCodec` produces: `rq/<path>Request` → `rr/<path>Reply`.
        if let replyHandler, let replyBytes = replyHandler(topic, data),
            let replyTopic = Self.replyTopic(forRequestTopic: topic)
        {
            deliver(toTopic: replyTopic, data: replyBytes, timestamp: 0)
        }
    }

    /// Map a `rq/<path>Request` topic to its paired `rr/<path>Reply` topic.
    /// Used by the in-process service-reply test hook. Returns `nil` if the
    /// input does not match the expected request-topic shape.
    private static func replyTopic(forRequestTopic topic: String) -> String? {
        guard topic.hasPrefix("rq/"), topic.hasSuffix("Request") else { return nil }
        let body = topic.dropFirst("rq/".count).dropLast("Request".count)
        return "rr/\(body)Reply"
    }

    func destroyWriter(_ writer: any DDSWriterHandle) {
        lock.lock()
        defer { lock.unlock() }
        destroyedWriters += 1
        (writer as? MockDDSWriterHandle)?.markClosed()
    }

    func createRawReader(
        topicName: String, typeName: String,
        qos: DDSBridgeQoSConfig, userData: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any DDSReaderHandle {
        lock.lock()
        defer { lock.unlock() }
        readers.append((topicName, typeName, qos, userData, handler))
        return MockDDSReaderHandle(topic: topicName)
    }

    func destroyReader(_ reader: any DDSReaderHandle) {
        lock.lock()
        defer { lock.unlock() }
        destroyedReaders += 1
        (reader as? MockDDSReaderHandle)?.markClosed()
    }

    /// Test helper: deliver a sample to readers on the given topic.
    func deliver(toTopic topic: String, data: Data, timestamp: UInt64) {
        let handlers: [(Data, UInt64) -> Void] = {
            lock.lock()
            defer { lock.unlock() }
            return readers.filter { $0.topic == topic }.map { $0.handler }
        }()
        for handler in handlers {
            handler(data, timestamp)
        }
    }

    /// Plan-spec alias for `deliver(toTopic:data:timestamp:)`. Async to mirror
    /// real-network callers; the underlying delivery is synchronous.
    func deliverToReader(topic: String, wire: Data, timestamp: UInt64) async throws {
        deliver(toTopic: topic, data: wire, timestamp: timestamp)
    }

    /// Test helper used by action / service tests: deliver a request-style
    /// sample (the bytes have already been wrapped by `SampleIdentityPrefix`)
    /// to readers on the given request topic. Synonym for `deliver` — exists
    /// to match the action-transport plan vocabulary.
    func deliverRequestSample(topic: String, data: Data) {
        deliver(toTopic: topic, data: data, timestamp: 0)
    }

    /// Test helper used by action tests: deliver a subscriber-style sample
    /// (e.g. a `_action/feedback` or `_action/status` frame) to readers on
    /// the given topic.
    func deliverSubscriberSample(topic: String, data: Data) {
        deliver(toTopic: topic, data: data, timestamp: 0)
    }

    /// Wait up to `timeout` for a `writeRawCDR` on `topic`. If one has
    /// already landed by the time this is called, it is returned immediately;
    /// otherwise the call suspends until the next write arrives or the
    /// timeout elapses. `writeRawCDR` resumes any pending waiter eagerly, so
    /// there is no poll latency. Returns `nil` only if the timeout elapsed
    /// without any write to `topic`.
    ///
    /// Tests call this at most once per topic, so "latest write or wait for
    /// first" semantics match the intent. A baseline-vs-count scheme races
    /// with eagerly-scheduled writer tasks (the writer can land on another
    /// thread before the baseline is captured, leaving the waiter blocked
    /// forever) — see PR fixing the x86_64 jazzy CI flake.
    func awaitWrite(topic: String, timeout: Duration) async throws -> Data? {
        // Returns true iff the write-watcher arm won the race; only then is
        // the recorded write within the timeout boundary and safe to return.
        // If the sleep arm wins first, return nil even if a late write lands
        // before `lastWritten` runs — otherwise tests would silently pass on
        // post-deadline writes and the timeout assertion becomes a lie.
        let writeWon = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitUntilWriteExists(topic: topic)
                return true
            }
            group.addTask {
                // Cancellation = the write came first. Swallow & exit.
                do {
                    try await Task.sleep(for: timeout)
                } catch {}
                return false
            }
            let winner = await group.next() ?? false
            group.cancelAll()
            self.flushWriteWaiters(topic: topic)
            await group.waitForAll()
            return winner
        }
        return writeWon ? lastWritten(topic: topic) : nil
    }

    /// Suspend until at least one write to `topic` has been recorded. The
    /// check + registration happen under `lock`, so a write that lands
    /// concurrently with the call cannot slip past us.
    private func waitUntilWriteExists(topic: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if writes.contains(where: { $0.topic == topic }) {
                lock.unlock()
                cont.resume()
                return
            }
            writeWaiters[topic, default: []].append(cont)
            lock.unlock()
        }
    }

    /// Resume any waiters registered for `topic` without recording a write —
    /// used to drain stale continuations after a timeout cancels the wait.
    private func flushWriteWaiters(topic: String) {
        let drained: [CheckedContinuation<Void, Never>]
        do {
            lock.lock()
            defer { lock.unlock() }
            drained = writeWaiters.removeValue(forKey: topic) ?? []
        }
        for waiter in drained { waiter.resume() }
    }

    /// Last write recorded on `topic`, or `nil` if no writes happened.
    func lastWritten(topic: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return writes.last(where: { $0.topic == topic })?.data
    }

    /// Mark the given DDS topic as having matched subscribers. Affects what
    /// `isPublicationMatched(writer:)` returns for any writer on that topic.
    func markPublicationsMatched(topic: String) {
        lock.lock()
        defer { lock.unlock() }
        matchedTopics.insert(topic)
    }

    func isPublicationMatched(writer: any DDSWriterHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let mock = writer as? MockDDSWriterHandle else { return false }
        return matchedTopics.contains(mock.topic)
    }

    // Subscription-match override (per topic). Used to drive `waitForService`.
    private var matchedReaderTopics: Set<String> = []

    /// Mark the given DDS topic as having matched publications. Affects what
    /// `isSubscriptionMatched(reader:)` returns for any reader on that topic.
    func markSubscriptionsMatched(topic: String) {
        lock.lock()
        defer { lock.unlock() }
        matchedReaderTopics.insert(topic)
    }

    func isSubscriptionMatched(reader: any DDSReaderHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let mock = reader as? MockDDSReaderHandle else { return false }
        return matchedReaderTopics.contains(mock.topic)
    }

    private var matchedCounts: [String: Int] = [:]

    /// Sets what `publicationMatchedCount(writer:)` returns for writers on `topic`;
    /// `nil` means unknown.
    func setMatchedCount(topic: String, _ count: Int?) {
        lock.lock()
        defer { lock.unlock() }
        matchedCounts[topic] = count
    }

    func publicationMatchedCount(writer: any DDSWriterHandle) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let mock = writer as? MockDDSWriterHandle else { return nil }
        return matchedCounts[mock.topic]
    }
}

final class MockDDSWriterHandle: DDSWriterHandle, @unchecked Sendable {
    let topic: String
    private var closed = false
    private let lock = NSLock()

    init(topic: String) { self.topic = topic }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    func markClosed() { close() }
}

final class MockDDSReaderHandle: DDSReaderHandle, @unchecked Sendable {
    let topic: String
    private var closed = false
    private let lock = NSLock()

    init(topic: String) { self.topic = topic }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    func markClosed() { close() }
}
