import Foundation
import SwiftROS2Transport

/// Ordered record of the teardown calls a `GatedTeardownSession` received.
final class TeardownLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: String) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }
}

/// Holds every caller of `pass()` until `open()` is called, and counts the
/// callers that have arrived.
final class TeardownGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var _arrivals = 0

    var arrivals: Int {
        condition.lock()
        defer { condition.unlock() }
        return _arrivals
    }

    func pass() {
        condition.lock()
        _arrivals += 1
        condition.broadcast()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until `count` callers have reached `pass()`. Returns `false` on timeout.
    func waitForArrivals(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while _arrivals < count {
            if !condition.wait(until: deadline) {
                return _arrivals >= count
            }
        }
        return true
    }
}

/// A `TransportSession` that records its teardown calls in order and can make
/// them block.
///
/// Closing an entity of a gated kind, or the session when `.session` is gated,
/// waits on `gate` until the test opens it, the way a wire Zenoh publisher
/// close waits for a put stuck on a frozen link. Each call is logged once it
/// has returned.
final class GatedTeardownSession: TransportSession, @unchecked Sendable {
    enum Step: String, Hashable {
        case publisher, subscriber, service, client, session
    }

    let log: TeardownLog
    private let gate: TeardownGate?
    private let gated: Set<Step>
    private let lock = NSLock()
    private var _isConnected = true
    private var _entities: [GatedTransportEntity] = []
    private var _servicesLeftBeforeFailure: Int?

    init(log: TeardownLog = TeardownLog(), gate: TeardownGate? = nil, gated: Set<Step> = []) {
        self.log = log
        self.gate = gate
        self.gated = gated
    }

    /// The entities created so far, in creation order.
    var entities: [GatedTransportEntity] {
        lock.lock()
        defer { lock.unlock() }
        return _entities
    }

    /// Makes `createServiceServer` throw once `count` servers have been created.
    func failServiceCreation(after count: Int) {
        lock.lock()
        _servicesLeftBeforeFailure = count
        lock.unlock()
    }

    /// Runs one teardown step: waits on the gate when the step is gated, then logs it.
    func teardown(_ step: Step, _ event: String) {
        if gated.contains(step) {
            gate?.pass()
        }
        log.append(event)
    }

    // MARK: - TransportSession

    var transportType: TransportType { .zenoh }
    var sessionId: String { "gated-teardown-session" }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    func open(config: TransportConfig) async throws {}

    func close() throws {
        teardown(.session, "session.close")
        lock.lock()
        _isConnected = false
        lock.unlock()
    }

    func checkHealth() -> Bool { isConnected }

    func unregisterNode(name: String, namespace: String) {
        log.append("unregister \(name)")
    }

    func createPublisher(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS
    ) throws -> any TransportPublisher {
        makeEntity(.publisher, topic)
    }

    func createSubscriber(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        makeEntity(.subscriber, topic)
    }

    func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        lock.lock()
        if let left = _servicesLeftBeforeFailure {
            guard left > 0 else {
                lock.unlock()
                throw TransportError.connectionFailed("simulated service creation failure")
            }
            _servicesLeftBeforeFailure = left - 1
        }
        lock.unlock()
        return makeEntity(.service, name)
    }

    func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient {
        makeEntity(.client, name)
    }

    private func makeEntity(_ step: Step, _ name: String) -> GatedTransportEntity {
        let entity = GatedTransportEntity(step: step, name: name, session: self)
        lock.lock()
        _entities.append(entity)
        lock.unlock()
        return entity
    }
}

/// One publisher, subscriber, service server or service client of a
/// `GatedTeardownSession`. Its `close()` runs the session's teardown step.
final class GatedTransportEntity: TransportPublisher, TransportSubscriber, TransportService,
    TransportClient, @unchecked Sendable
{
    let step: GatedTeardownSession.Step
    let topic: String
    var name: String { topic }

    private let session: GatedTeardownSession
    private let lock = NSLock()
    private var closed = false
    private var _matched: Bool? = true

    init(step: GatedTeardownSession.Step, name: String, session: GatedTeardownSession) {
        self.step = step
        self.topic = name
        self.session = session
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    /// What `matchedSubscriptions` reports.
    var matched: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _matched
        }
        set {
            lock.lock()
            _matched = newValue
            lock.unlock()
        }
    }

    var matchedSubscriptions: Bool? { matched }

    func publish(data: Data, timestamp: UInt64, sequenceNumber: Int64) throws {}

    func waitForService(timeout: Duration) async throws {}

    func call(requestCDR: Data, timeout: Duration) async throws -> Data {
        throw TransportError.notConnected
    }

    func close() throws {
        session.teardown(step, "\(step.rawValue).close \(topic)")
        lock.lock()
        closed = true
        lock.unlock()
    }
}
