import Foundation
import SwiftROS2Transport

/// In-memory TransportSession used by SwiftROS2 umbrella unit tests.
///
/// Records publisher/subscriber creations and forwards published payloads
/// through the matching subscriber's handler so tests can drive end-to-end
/// flow without any real transport.
///
/// All mutable state is private and read/written only inside `synchronized`.
/// Public accessors (including the `*ShouldThrow` knobs and `isConnected`
/// setter that tests reach for directly) take the lock so the type's
/// `@unchecked Sendable` conformance is honest under `swift test --parallel`.
final class MockTransportSession: TransportSession, @unchecked Sendable {
    private let lock = NSLock()

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var transportType: TransportType { .zenoh }

    // MARK: - Mutable state (private + lock-guarded)

    private var _isConnected = true
    private var _sessionIdValue = "mock-umbrella-session"
    private var _openShouldThrow: TransportError?
    private var _closeShouldThrow: TransportError?
    private var _registerNodeShouldThrow: TransportError?
    private var _createPublisherShouldThrow: TransportError?
    private var _createSubscriberShouldThrow: TransportError?
    private var _openedConfigs: [TransportConfig] = []
    private var _publishers: [MockTransportPublisher] = []
    private var _subscribers: [MockTransportSubscriber] = []
    private var _closedCount = 0
    private var _registeredNodes: [(name: String, namespace: String)] = []
    private var _unregisteredNodes: [(name: String, namespace: String)] = []

    // Service-related state. Default-disabled so tests that don't opt in
    // keep getting the original "unsupportedFeature" throw.
    private var _serviceMode: ServiceMode = .unsupported
    private var _services: [MockTransportServiceServer] = []
    private var _clients: [MockTransportServiceClient] = []

    enum ServiceMode {
        /// `createServiceServer` / `createServiceClient` throw `unsupportedFeature`.
        case unsupported
        /// In-process echo: client `call` invokes the matching server's handler.
        case echo
        /// Client `call` always sleeps for the requested timeout, then throws.
        case neverResponds
    }

    // MARK: - Public accessors (synchronized)

    var isConnected: Bool {
        get { synchronized { _isConnected } }
        set { synchronized { _isConnected = newValue } }
    }

    var sessionId: String {
        get { synchronized { _sessionIdValue } }
        set { synchronized { _sessionIdValue = newValue } }
    }

    var openShouldThrow: TransportError? {
        get { synchronized { _openShouldThrow } }
        set { synchronized { _openShouldThrow = newValue } }
    }

    var closeShouldThrow: TransportError? {
        get { synchronized { _closeShouldThrow } }
        set { synchronized { _closeShouldThrow = newValue } }
    }

    var registerNodeShouldThrow: TransportError? {
        get { synchronized { _registerNodeShouldThrow } }
        set { synchronized { _registerNodeShouldThrow = newValue } }
    }

    var createPublisherShouldThrow: TransportError? {
        get { synchronized { _createPublisherShouldThrow } }
        set { synchronized { _createPublisherShouldThrow = newValue } }
    }

    var createSubscriberShouldThrow: TransportError? {
        get { synchronized { _createSubscriberShouldThrow } }
        set { synchronized { _createSubscriberShouldThrow = newValue } }
    }

    var openedConfigs: [TransportConfig] { synchronized { _openedConfigs } }
    var publishers: [MockTransportPublisher] { synchronized { _publishers } }
    var subscribers: [MockTransportSubscriber] { synchronized { _subscribers } }
    var closedCount: Int { synchronized { _closedCount } }
    var registeredNodes: [(name: String, namespace: String)] { synchronized { _registeredNodes } }
    var unregisteredNodes: [(name: String, namespace: String)] { synchronized { _unregisteredNodes } }

    // MARK: - TransportSession

    func open(config: TransportConfig) async throws {
        if let e = synchronized({ _openShouldThrow }) { throw e }
        // Mirror real Zenoh / DDS sessions: reject configs whose transport type
        // doesn't match this session and run the same validate() check.
        guard config.type == transportType else {
            throw TransportError.invalidConfiguration(
                "Expected \(transportType) configuration, got \(config.type)"
            )
        }
        try config.validate()
        synchronized {
            _openedConfigs.append(config)
            _isConnected = true
        }
    }

    func close() throws {
        let (publishersToClose, subscribersToClose): ([MockTransportPublisher], [MockTransportSubscriber]) =
            synchronized {
                _closedCount += 1
                _isConnected = false
                return (_publishers, _subscribers)
            }
        for publisher in publishersToClose {
            try publisher.close()
        }
        for subscriber in subscribersToClose {
            try subscriber.close()
        }
        if let e = synchronized({ _closeShouldThrow }) { throw e }
    }

    func createPublisher(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS
    ) throws -> any TransportPublisher {
        // Snapshot the throw-knob and connection state in a single critical section
        // so a concurrent flip can't slip between checks.
        let connected: Bool = try synchronized {
            if let e = _createPublisherShouldThrow { throw e }
            return _isConnected
        }
        // Mirror real Zenoh / DDS sessions: refuse on a closed session and
        // reject empty topic / type names.
        guard connected else {
            throw TransportError.notConnected
        }
        guard !topic.isEmpty else {
            throw TransportError.invalidConfiguration("Topic name cannot be empty")
        }
        guard !typeName.isEmpty else {
            throw TransportError.invalidConfiguration("Type name cannot be empty")
        }
        let pub = MockTransportPublisher(topic: topic, typeName: typeName, typeHash: typeHash, qos: qos)
        synchronized { _publishers.append(pub) }
        // Wire publisher → matching subscribers so publish() forwards through.
        // Match on topic + typeName + typeHash, and skip subscribers that
        // have already been closed/cancelled.
        pub.deliveryFanout = { [weak self] data, ts in
            guard let self = self else { return }
            let matches: [MockTransportSubscriber] = self.synchronized {
                self._subscribers.filter { sub in
                    sub.isActive && sub.topic == topic && sub.typeName == typeName && sub.typeHash == typeHash
                }
            }
            for sub in matches {
                sub.handler(data, ts)
            }
        }
        return pub
    }

    func createSubscriber(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any TransportSubscriber {
        let connected: Bool = try synchronized {
            if let e = _createSubscriberShouldThrow { throw e }
            return _isConnected
        }
        guard connected else {
            throw TransportError.notConnected
        }
        guard !topic.isEmpty else {
            throw TransportError.invalidConfiguration("Topic name cannot be empty")
        }
        guard !typeName.isEmpty else {
            throw TransportError.invalidConfiguration("Type name cannot be empty")
        }
        let sub = MockTransportSubscriber(
            topic: topic,
            typeName: typeName,
            typeHash: typeHash,
            qos: qos,
            handler: handler
        )
        synchronized { _subscribers.append(sub) }
        return sub
    }

    func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        let mode: ServiceMode = synchronized { _serviceMode }
        switch mode {
        case .unsupported:
            throw TransportError.unsupportedFeature(
                "MockTransportSession service server (override per test)"
            )
        case .echo, .neverResponds:
            let svc = MockTransportServiceServer(name: name, handler: handler)
            synchronized { _services.append(svc) }
            return svc
        }
    }

    func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient {
        let mode: ServiceMode = synchronized { _serviceMode }
        switch mode {
        case .unsupported:
            throw TransportError.unsupportedFeature(
                "MockTransportSession service client (override per test)"
            )
        case .echo:
            let cli = MockTransportServiceClient(name: name, mode: .echo) { [weak self] req in
                guard let self = self else { return Data() }
                let target: MockTransportServiceServer? = self.synchronized {
                    self._services.first(where: { $0.name == name })
                }
                if let svc = target {
                    return try await svc.handler(req)
                }
                throw TransportError.notConnected
            }
            synchronized { _clients.append(cli) }
            return cli
        case .neverResponds:
            let cli = MockTransportServiceClient(name: name, mode: .neverResponds) { _ in
                Data()  // never reached
            }
            synchronized { _clients.append(cli) }
            return cli
        }
    }

    func registerNode(name: String, namespace: String) throws {
        if let e = synchronized({ _registerNodeShouldThrow }) { throw e }
        synchronized { _registeredNodes.append((name, namespace)) }
    }

    func unregisterNode(name: String, namespace: String) {
        synchronized { _unregisteredNodes.append((name, namespace)) }
    }

    // MARK: - Action overrides

    /// Optional factory used by `createActionServer` if set. Signature:
    /// `(name, actionTypeName, roleTypeHashes, qos, handlers) -> any TransportActionServer`.
    var actionServerFactory:
        (
            @Sendable (
                String, String, ActionRoleTypeHashes, TransportQoS,
                TransportActionServerHandlers
            ) -> any TransportActionServer
        )?

    /// Optional factory used by `createActionClient` if set. Signature:
    /// `(name, actionTypeName, roleTypeHashes, qos) -> any TransportActionClient`.
    var actionClientFactory:
        (
            @Sendable (
                String, String, ActionRoleTypeHashes, TransportQoS
            ) -> any TransportActionClient
        )?

    func createActionServer(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS,
        handlers: TransportActionServerHandlers
    ) throws -> any TransportActionServer {
        if let f = actionServerFactory {
            return f(name, actionTypeName, roleTypeHashes, qos, handlers)
        }
        throw TransportError.unsupportedFeature("MockTransportSession action server")
    }

    func createActionClient(
        name: String,
        actionTypeName: String,
        roleTypeHashes: ActionRoleTypeHashes,
        qos: TransportQoS
    ) throws -> any TransportActionClient {
        if let f = actionClientFactory {
            return f(name, actionTypeName, roleTypeHashes, qos)
        }
        throw TransportError.unsupportedFeature("MockTransportSession action client")
    }

    // MARK: - Service test helpers

    /// Make subsequent `createServiceServer` / `createServiceClient` calls
    /// produce in-process cooperating mocks: a client's `call` looks up the
    /// matching server by name and invokes its handler directly.
    func installEchoServiceTransport() {
        synchronized { _serviceMode = .echo }
    }

    /// Make `createServiceClient` produce a client whose `call` sleeps for
    /// the supplied timeout and then throws `requestTimeout`. Useful for
    /// driving the umbrella's timeout mapping path.
    func installNeverRespondingServiceTransport() {
        synchronized { _serviceMode = .neverResponds }
    }
}

final class MockTransportPublisher: TransportPublisher, @unchecked Sendable {
    let topic: String
    let typeName: String
    let typeHash: String?
    let qos: TransportQoS

    private let lock = NSLock()
    private var closed = false
    private var _publishedPayloads: [(data: Data, timestamp: UInt64, sequenceNumber: Int64)] = []
    var deliveryFanout: ((Data, UInt64) -> Void)?

    /// Snapshot of payloads observed so far, returned under the lock.
    /// Reading the underlying storage without locking races against the
    /// `publish(...)` writer — on Linux x86_64 (Swift 6.0 runtime) the
    /// detector aborts the process with a "_ContiguousArrayStorage
    /// deallocated with non-zero retain count" message; on other targets
    /// it can silently mis-observe. Always go through the snapshot.
    var publishedPayloads: [(data: Data, timestamp: UInt64, sequenceNumber: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return _publishedPayloads
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    private var _matched: Bool?
    /// What `matchedSubscriptions` reports; `nil` means "cannot tell".
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

    init(topic: String, typeName: String, typeHash: String?, qos: TransportQoS) {
        self.topic = topic
        self.typeName = typeName
        self.typeHash = typeHash
        self.qos = qos
    }

    func publish(data: Data, timestamp: UInt64, sequenceNumber: Int64) throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            throw TransportError.publisherClosed
        }
        _publishedPayloads.append((data, timestamp, sequenceNumber))
        let fanout = deliveryFanout
        lock.unlock()
        fanout?(data, timestamp)
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }
}

final class MockTransportServiceServer: TransportService, @unchecked Sendable {
    let name: String
    let handler: @Sendable (Data) async throws -> Data
    private let lock = NSLock()
    private var closed = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    init(name: String, handler: @escaping @Sendable (Data) async throws -> Data) {
        self.name = name
        self.handler = handler
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }
}

final class MockTransportServiceClient: TransportClient, @unchecked Sendable {
    enum Mode {
        case echo
        case neverResponds
    }

    let name: String
    private let mode: Mode
    private let dispatch: @Sendable (Data) async throws -> Data
    private let lock = NSLock()
    private var closed = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    init(name: String, mode: Mode, dispatch: @escaping @Sendable (Data) async throws -> Data) {
        self.name = name
        self.mode = mode
        self.dispatch = dispatch
    }

    func waitForService(timeout: Duration) async throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        if isClosed {
            throw TransportError.sessionClosed
        }
    }

    func call(requestCDR: Data, timeout: Duration) async throws -> Data {
        lock.lock()
        if closed {
            lock.unlock()
            throw TransportError.sessionClosed
        }
        lock.unlock()

        switch mode {
        case .echo:
            return try await dispatch(requestCDR)
        case .neverResponds:
            try? await Task.sleep(for: timeout)
            try Task.checkCancellation()
            throw TransportError.requestTimeout(timeout)
        }
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }
}

final class MockTransportSubscriber: TransportSubscriber, @unchecked Sendable {
    let topic: String
    let typeName: String
    let typeHash: String?
    let qos: TransportQoS
    let handler: @Sendable (Data, UInt64) -> Void

    private let lock = NSLock()
    private var closed = false

    init(
        topic: String, typeName: String, typeHash: String?, qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) {
        self.topic = topic
        self.typeName = typeName
        self.typeHash = typeHash
        self.qos = qos
        self.handler = handler
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }
}
