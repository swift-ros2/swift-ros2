import Foundation

@testable import SwiftROS2Transport

final class MockRclNode: RclNodeHandle, @unchecked Sendable {
    let name: String
    let namespace: String
    init(name: String, namespace: String) {
        self.name = name
        self.namespace = namespace
    }
}

final class MockRclPublisher: RclPublisherHandle, @unchecked Sendable {
    let node: any RclNodeHandle
    let topic: String
    let typeName: String
    private let lock = NSLock()
    private var closed = false
    init(node: any RclNodeHandle, topic: String, typeName: String) {
        self.node = node
        self.topic = topic
        self.typeName = typeName
    }
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
}

final class MockRclSubscription: RclSubscriptionHandle, @unchecked Sendable {
    let node: any RclNodeHandle
    let topic: String
    let typeName: String
    let typeHash: String?
    let qos: TransportQoS
    private let handler: @Sendable (Data, UInt64) -> Void
    private let lock = NSLock()
    private var destroyed = false

    init(
        node: any RclNodeHandle, topic: String, typeName: String, typeHash: String?,
        qos: TransportQoS, handler: @escaping @Sendable (Data, UInt64) -> Void
    ) {
        self.node = node
        self.topic = topic
        self.typeName = typeName
        self.typeHash = typeHash
        self.qos = qos
        self.handler = handler
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !destroyed
    }

    func markDestroyed() {
        lock.lock()
        defer { lock.unlock() }
        destroyed = true
    }

    /// Test hook: simulate the wait thread delivering one taken message.
    func fire(_ data: Data, timestamp: UInt64) {
        handler(data, timestamp)
    }
}

final class MockRclService: RclServiceHandle, @unchecked Sendable {
    let node: any RclNodeHandle
    let serviceName: String
    let srvTypeName: String
    let qos: TransportQoS
    private let onRequest: @Sendable (Data, [UInt8]) -> Void
    private let lock = NSLock()
    private var destroyed = false
    /// Responses recorded by MockRclClient.sendResponse, in send order.
    private(set) var responsesSent: [(requestId: [UInt8], data: Data)] = []

    init(
        node: any RclNodeHandle, serviceName: String, srvTypeName: String, qos: TransportQoS,
        onRequest: @escaping @Sendable (Data, [UInt8]) -> Void
    ) {
        self.node = node
        self.serviceName = serviceName
        self.srvTypeName = srvTypeName
        self.qos = qos
        self.onRequest = onRequest
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !destroyed
    }

    func markDestroyed() {
        lock.lock()
        defer { lock.unlock() }
        destroyed = true
    }

    func recordResponse(requestId: [UInt8], data: Data) {
        lock.lock()
        defer { lock.unlock() }
        responsesSent.append((requestId, data))
    }

    /// Test hook: simulate the wait thread delivering one taken request.
    func fire(_ data: Data, requestId: [UInt8]) {
        onRequest(data, requestId)
    }
}

final class MockRclServiceClient: RclClientHandle, @unchecked Sendable {
    let node: any RclNodeHandle
    let serviceName: String
    let srvTypeName: String
    let qos: TransportQoS
    private let onResponse: @Sendable (Int64, Data) -> Void
    private let lock = NSLock()
    private var destroyed = false
    private var nextSeq: Int64 = 0
    /// Requests recorded by MockRclClient.sendRequest, in send order; the
    /// element index + 1 is the sequence number that was returned.
    private(set) var sentRequests: [Data] = []

    init(
        node: any RclNodeHandle, serviceName: String, srvTypeName: String, qos: TransportQoS,
        onResponse: @escaping @Sendable (Int64, Data) -> Void
    ) {
        self.node = node
        self.serviceName = serviceName
        self.srvTypeName = srvTypeName
        self.qos = qos
        self.onResponse = onResponse
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !destroyed
    }

    func markDestroyed() {
        lock.lock()
        defer { lock.unlock() }
        destroyed = true
    }

    func recordRequest(_ data: Data) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        sentRequests.append(data)
        return nextSeq
    }

    /// Test hook: simulate the wait thread delivering one taken response.
    func fire(sequenceNumber: Int64, data: Data) {
        onResponse(sequenceNumber, data)
    }
}

final class MockRclActionServer: RclActionServerHandle, @unchecked Sendable {
    let node: any RclNodeHandle
    let actionName: String
    let actionTypeName: String
    let qos: TransportQoS
    private let callbacks: RclActionServerCallbacks
    private let lock = NSLock()
    private var destroyed = false
    /// Responses recorded by the three send calls, in send order, tagged by role.
    private(set) var goalResponsesSent: [(requestId: [UInt8], data: Data)] = []
    private(set) var cancelResponsesSent: [(requestId: [UInt8], data: Data)] = []
    private(set) var resultResponsesSent: [(requestId: [UInt8], data: Data)] = []
    private(set) var feedbackPublished: [Data] = []
    private(set) var statusPublishCount = 0
    private(set) var acceptedGoals: [(goalId: [UInt8], stampSec: Int32, stampNanosec: UInt32)] = []
    private(set) var goalStateUpdates: [(goalId: [UInt8], event: RclGoalEvent)] = []
    private(set) var notifyGoalDoneCount = 0

    init(
        node: any RclNodeHandle, actionName: String, actionTypeName: String, qos: TransportQoS,
        callbacks: RclActionServerCallbacks
    ) {
        self.node = node
        self.actionName = actionName
        self.actionTypeName = actionTypeName
        self.qos = qos
        self.callbacks = callbacks
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !destroyed
    }

    func markDestroyed() {
        lock.lock()
        defer { lock.unlock() }
        destroyed = true
    }

    func sync(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body()
    }

    func recordGoalResponse(requestId: [UInt8], data: Data) {
        sync { goalResponsesSent.append((requestId, data)) }
    }
    func recordCancelResponse(requestId: [UInt8], data: Data) {
        sync { cancelResponsesSent.append((requestId, data)) }
    }
    func recordResultResponse(requestId: [UInt8], data: Data) {
        sync { resultResponsesSent.append((requestId, data)) }
    }
    func recordFeedback(_ data: Data) {
        sync { feedbackPublished.append(data) }
    }
    func recordStatusPublish() {
        sync { statusPublishCount += 1 }
    }
    func recordAccept(goalId: [UInt8], stampSec: Int32, stampNanosec: UInt32) {
        sync { acceptedGoals.append((goalId, stampSec, stampNanosec)) }
    }
    func recordGoalStateUpdate(goalId: [UInt8], event: RclGoalEvent) {
        sync { goalStateUpdates.append((goalId, event)) }
    }
    func recordNotifyGoalDone() {
        sync { notifyGoalDoneCount += 1 }
    }

    /// Test hooks: simulate the wait thread delivering one taken request.
    func fireGoalRequest(_ data: Data, requestId: [UInt8]) {
        callbacks.onGoalRequest(data, requestId)
    }
    func fireCancelRequest(_ data: Data, requestId: [UInt8]) {
        callbacks.onCancelRequest(data, requestId)
    }
    func fireResultRequest(_ data: Data, requestId: [UInt8]) {
        callbacks.onResultRequest(data, requestId)
    }
}

final class MockRclActionClient: RclActionClientHandle, @unchecked Sendable {
    let node: any RclNodeHandle
    let actionName: String
    let actionTypeName: String
    let qos: TransportQoS
    private let callbacks: RclActionClientCallbacks
    private let lock = NSLock()
    private var destroyed = false
    private var nextSeq: Int64 = 0
    /// Requests recorded by the three send calls, in send order, tagged by
    /// role; the recorded sequence number is what the send returned.
    private(set) var goalRequestsSent: [(seq: Int64, data: Data)] = []
    private(set) var cancelRequestsSent: [(seq: Int64, data: Data)] = []
    private(set) var resultRequestsSent: [(seq: Int64, data: Data)] = []

    init(
        node: any RclNodeHandle, actionName: String, actionTypeName: String, qos: TransportQoS,
        callbacks: RclActionClientCallbacks
    ) {
        self.node = node
        self.actionName = actionName
        self.actionTypeName = actionTypeName
        self.qos = qos
        self.callbacks = callbacks
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !destroyed
    }

    func markDestroyed() {
        lock.lock()
        defer { lock.unlock() }
        destroyed = true
    }

    func recordGoalRequest(_ data: Data) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        goalRequestsSent.append((nextSeq, data))
        return nextSeq
    }
    func recordCancelRequest(_ data: Data) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        cancelRequestsSent.append((nextSeq, data))
        return nextSeq
    }
    func recordResultRequest(_ data: Data) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        nextSeq += 1
        resultRequestsSent.append((nextSeq, data))
        return nextSeq
    }

    /// Test hooks: simulate the wait thread delivering one taken message.
    func fireGoalResponse(sequenceNumber: Int64, data: Data) {
        callbacks.onGoalResponse(sequenceNumber, data)
    }
    func fireCancelResponse(sequenceNumber: Int64, data: Data) {
        callbacks.onCancelResponse(sequenceNumber, data)
    }
    func fireResultResponse(sequenceNumber: Int64, data: Data) {
        callbacks.onResultResponse(sequenceNumber, data)
    }
    func fireFeedback(_ data: Data) {
        callbacks.onFeedback(data)
    }
    func fireStatus(_ records: [RclGoalStatusRecord]) {
        callbacks.onStatus(records)
    }
}

final class MockRclClient: RclClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private func sync<T>(_ b: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return b()
    }

    var isAvailable = true

    private(set) var contextCreated = false
    private(set) var contextDestroyed = false
    private(set) var lastDomainId: Int32 = -1
    private(set) var lastTransportType: TransportType?
    private(set) var lastUnicastPeerAddresses: [String] = []
    private(set) var lastNetworkInterface: String?
    /// Records the zenoh router locator passed to createContext (wrapped in Optional
    /// to distinguish "called with nil" from "never called").
    private(set) var recordedZenohLocator: String??
    private(set) var nodesCreated: [(name: String, namespace: String)] = []
    /// Handles returned by createNode, in creation order — lets tests assert
    /// entity-to-node attachment by identity.
    private(set) var nodeHandles: [MockRclNode] = []
    private(set) var nodesDestroyed: [(name: String, namespace: String)] = []
    private(set) var publishersCreated: [(topic: String, typeName: String)] = []
    /// Publisher handles returned by createPublisher, in creation order — lets
    /// tests assert entity-to-node attachment by identity (mirrors subscriptionsCreated).
    private(set) var publisherHandles: [MockRclPublisher] = []
    private(set) var publishedPayloads: [Data] = []
    private(set) var subscriptionsCreated: [MockRclSubscription] = []
    private(set) var subscriptionsDestroyed: [(topic: String, typeName: String)] = []
    private(set) var servicesCreated: [MockRclService] = []
    private(set) var servicesDestroyed: [(serviceName: String, srvTypeName: String)] = []
    private(set) var serviceClientsCreated: [MockRclServiceClient] = []
    private(set) var serviceClientsDestroyed: [(serviceName: String, srvTypeName: String)] = []
    private(set) var actionServersCreated: [MockRclActionServer] = []
    private(set) var actionServersDestroyed: [(actionName: String, actionTypeName: String)] = []
    private(set) var actionClientsCreated: [MockRclActionClient] = []
    private(set) var actionClientsDestroyed: [(actionName: String, actionTypeName: String)] = []
    /// Teardown order log: "subscription:<topic>" / "service:<name>" /
    /// "client:<name>" / "node:<name>" / "context".
    private(set) var teardownEvents: [String] = []

    var createPublisherShouldThrow: TransportError?
    var createSubscriptionShouldThrow: TransportError?
    var createServiceServerShouldThrow: TransportError?
    var createActionServerShouldThrow: TransportError?
    var sendRequestShouldThrow: TransportError?
    var sendGoalRequestShouldThrow: TransportError?
    var acceptGoalShouldThrow: TransportError?
    /// Events for which `updateGoalState` throws — lets tests fail a chain
    /// partway through (e.g. `.execute` lands, `.succeed` fails).
    var updateGoalStateShouldThrowOn: Set<RclGoalEvent> = []
    var serverAvailableValue = true
    var actionServerAvailableValue = true
    /// Test hook: runs inside createSubscription before the handle is
    /// returned — lets tests interleave a session close() into the
    /// preflight-create-append window.
    var onCreateSubscription: (() -> Void)?
    /// Same close-race hooks for the service entities.
    var onCreateServiceServer: (() -> Void)?
    var onCreateServiceClient: (() -> Void)?
    /// Same close-race hooks for the action entities.
    var onCreateActionServer: (() -> Void)?
    var onCreateActionClient: (() -> Void)?
    /// Test hook: fires after a goal request is recorded, with its sequence number.
    var onSendGoalRequest: ((Int64, Data) -> Void)?
    /// Test hook: runs inside `acceptGoal` before the accept is recorded —
    /// lets tests hold the accept FFI call open while a racing status
    /// snapshot is attempted (the accept-vs-execute mirror race).
    var onAcceptGoal: (() -> Void)?
    /// Thrown by `createNode`, for every node.
    var createNodeShouldThrow: TransportError?
    /// What `graphPublishers(node:)` returns.
    var graphRecords: [RclGraphPublisherRecord] = []
    /// Thrown by `graphPublishers(node:)` instead of returning `graphRecords`.
    var graphPublishersShouldThrow: (any Error)?
    /// Test hook: runs inside `graphPublishers(node:)` before it returns — lets
    /// tests hold a snapshot open while the session closes.
    var onGraphPublishers: (() -> Void)?
    /// The node of each `graphPublishers(node:)` call, in call order.
    private(set) var graphQueryNodes: [MockRclNode] = []

    func createContext(
        domainId: Int32, transportType: TransportType, unicastPeerAddresses: [String],
        networkInterface: String?, zenohRouterLocator: String?
    ) throws {
        sync {
            contextCreated = true
            lastDomainId = domainId
            lastTransportType = transportType
            lastUnicastPeerAddresses = unicastPeerAddresses
            lastNetworkInterface = networkInterface
            recordedZenohLocator = Optional(zenohRouterLocator)
        }
    }
    func destroyContext() {
        sync {
            contextDestroyed = true
            teardownEvents.append("context")
        }
    }

    func createNode(name: String, namespace: String) throws -> any RclNodeHandle {
        if let e = sync({ createNodeShouldThrow }) { throw e }
        let node = MockRclNode(name: name, namespace: namespace)
        sync {
            nodesCreated.append((name, namespace))
            nodeHandles.append(node)
        }
        return node
    }
    func destroyNode(_ node: any RclNodeHandle) {
        guard let n = node as? MockRclNode else { return }
        sync {
            nodesDestroyed.append((n.name, n.namespace))
            teardownEvents.append("node:\(n.name)")
        }
    }

    func createPublisher(
        node: any RclNodeHandle, typeName: String, typeHash: String?, topic: String,
        qos: TransportQoS
    ) throws -> any RclPublisherHandle {
        if let e = createPublisherShouldThrow { throw e }
        let pub = MockRclPublisher(node: node, topic: topic, typeName: typeName)
        sync {
            publishersCreated.append((topic, typeName))
            publisherHandles.append(pub)
        }
        return pub
    }

    func publishSerialized(_ publisher: any RclPublisherHandle, data: Data) throws {
        sync { publishedPayloads.append(data) }
    }

    private var matchedCountsByTopic: [String: Int] = [:]

    /// Sets what `publisherMatchedCount(_:)` returns for publishers on `topic`; `nil` means unknown.
    func setPublisherMatchedCount(topic: String, _ count: Int?) {
        sync { matchedCountsByTopic[topic] = count }
    }

    func publisherMatchedCount(_ publisher: any RclPublisherHandle) -> Int? {
        guard let p = publisher as? MockRclPublisher else { return nil }
        return sync { matchedCountsByTopic[p.topic] }
    }

    func createSubscription(
        node: any RclNodeHandle,
        typeName: String,
        typeHash: String?,
        topic: String,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any RclSubscriptionHandle {
        if let e = createSubscriptionShouldThrow { throw e }
        onCreateSubscription?()
        let sub = MockRclSubscription(
            node: node, topic: topic, typeName: typeName, typeHash: typeHash, qos: qos,
            handler: handler)
        sync { subscriptionsCreated.append(sub) }
        return sub
    }

    func destroySubscription(_ subscription: any RclSubscriptionHandle) {
        guard let s = subscription as? MockRclSubscription else { return }
        s.markDestroyed()
        sync {
            subscriptionsDestroyed.append((s.topic, s.typeName))
            teardownEvents.append("subscription:\(s.topic)")
        }
    }

    func createServiceServer(
        node: any RclNodeHandle,
        srvTypeName: String,
        serviceName: String,
        qos: TransportQoS,
        onRequest: @escaping @Sendable (Data, [UInt8]) -> Void
    ) throws -> any RclServiceHandle {
        if let e = createServiceServerShouldThrow { throw e }
        onCreateServiceServer?()
        let service = MockRclService(
            node: node, serviceName: serviceName, srvTypeName: srvTypeName, qos: qos,
            onRequest: onRequest)
        sync { servicesCreated.append(service) }
        return service
    }

    func sendResponse(_ service: any RclServiceHandle, requestId: [UInt8], data: Data) throws {
        guard let s = service as? MockRclService else { return }
        guard s.isActive else { throw TransportError.sessionClosed }
        s.recordResponse(requestId: requestId, data: data)
    }

    func destroyServiceServer(_ service: any RclServiceHandle) {
        guard let s = service as? MockRclService else { return }
        s.markDestroyed()
        sync {
            servicesDestroyed.append((s.serviceName, s.srvTypeName))
            teardownEvents.append("service:\(s.serviceName)")
        }
    }

    func createServiceClient(
        node: any RclNodeHandle,
        srvTypeName: String,
        serviceName: String,
        qos: TransportQoS,
        onResponse: @escaping @Sendable (Int64, Data) -> Void
    ) throws -> any RclClientHandle {
        onCreateServiceClient?()
        let serviceClient = MockRclServiceClient(
            node: node, serviceName: serviceName, srvTypeName: srvTypeName, qos: qos,
            onResponse: onResponse)
        sync { serviceClientsCreated.append(serviceClient) }
        return serviceClient
    }

    func sendRequest(_ client: any RclClientHandle, data: Data) throws -> Int64 {
        if let e = sendRequestShouldThrow { throw e }
        guard let c = client as? MockRclServiceClient else {
            throw TransportError.publishFailed("invalid service client handle")
        }
        guard c.isActive else { throw TransportError.sessionClosed }
        let seq = c.recordRequest(data)
        return seq
    }

    func serverAvailable(_ client: any RclClientHandle) -> Bool {
        guard let c = client as? MockRclServiceClient, c.isActive else { return false }
        return serverAvailableValue
    }

    func destroyServiceClient(_ client: any RclClientHandle) {
        guard let c = client as? MockRclServiceClient else { return }
        c.markDestroyed()
        sync {
            serviceClientsDestroyed.append((c.serviceName, c.srvTypeName))
            teardownEvents.append("client:\(c.serviceName)")
        }
    }

    // MARK: Actions

    func createActionServer(
        node: any RclNodeHandle,
        actionTypeName: String,
        actionName: String,
        qos: TransportQoS,
        callbacks: RclActionServerCallbacks
    ) throws -> any RclActionServerHandle {
        if let e = createActionServerShouldThrow { throw e }
        onCreateActionServer?()
        let server = MockRclActionServer(
            node: node, actionName: actionName, actionTypeName: actionTypeName, qos: qos,
            callbacks: callbacks)
        sync { actionServersCreated.append(server) }
        return server
    }

    func sendGoalResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws
    {
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.sessionClosed
        }
        s.recordGoalResponse(requestId: requestId, data: data)
    }

    func sendCancelResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws
    {
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.sessionClosed
        }
        s.recordCancelResponse(requestId: requestId, data: data)
    }

    func sendResultResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws
    {
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.sessionClosed
        }
        s.recordResultResponse(requestId: requestId, data: data)
    }

    func publishActionFeedback(_ server: any RclActionServerHandle, data: Data) throws {
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.publisherClosed
        }
        s.recordFeedback(data)
    }

    func publishActionStatus(_ server: any RclActionServerHandle) throws {
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.publisherClosed
        }
        s.recordStatusPublish()
    }

    func acceptGoal(
        _ server: any RclActionServerHandle, goalId: [UInt8], stampSec: Int32,
        stampNanosec: UInt32
    ) throws {
        if let e = acceptGoalShouldThrow { throw e }
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.sessionClosed
        }
        onAcceptGoal?()
        s.recordAccept(goalId: goalId, stampSec: stampSec, stampNanosec: stampNanosec)
    }

    func updateGoalState(_ server: any RclActionServerHandle, goalId: [UInt8], event: RclGoalEvent)
        throws
    {
        if updateGoalStateShouldThrowOn.contains(event) {
            throw TransportError.publishFailed("updateGoalState(\(event)) refused by test")
        }
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.sessionClosed
        }
        s.recordGoalStateUpdate(goalId: goalId, event: event)
    }

    func notifyGoalDone(_ server: any RclActionServerHandle) throws {
        guard let s = server as? MockRclActionServer, s.isActive else {
            throw TransportError.sessionClosed
        }
        s.recordNotifyGoalDone()
    }

    func destroyActionServer(_ server: any RclActionServerHandle) {
        guard let s = server as? MockRclActionServer else { return }
        s.markDestroyed()
        sync {
            actionServersDestroyed.append((s.actionName, s.actionTypeName))
            teardownEvents.append("actionServer:\(s.actionName)")
        }
    }

    func createActionClient(
        node: any RclNodeHandle,
        actionTypeName: String,
        actionName: String,
        qos: TransportQoS,
        callbacks: RclActionClientCallbacks
    ) throws -> any RclActionClientHandle {
        onCreateActionClient?()
        let actionClient = MockRclActionClient(
            node: node, actionName: actionName, actionTypeName: actionTypeName, qos: qos,
            callbacks: callbacks)
        sync { actionClientsCreated.append(actionClient) }
        return actionClient
    }

    func sendGoalRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
        if let e = sendGoalRequestShouldThrow { throw e }
        guard let c = client as? MockRclActionClient, c.isActive else {
            throw TransportError.sessionClosed
        }
        let seq = c.recordGoalRequest(data)
        onSendGoalRequest?(seq, data)
        return seq
    }

    func sendCancelRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
        guard let c = client as? MockRclActionClient, c.isActive else {
            throw TransportError.sessionClosed
        }
        return c.recordCancelRequest(data)
    }

    func sendResultRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
        guard let c = client as? MockRclActionClient, c.isActive else {
            throw TransportError.sessionClosed
        }
        return c.recordResultRequest(data)
    }

    func actionServerAvailable(_ client: any RclActionClientHandle) -> Bool {
        guard let c = client as? MockRclActionClient, c.isActive else { return false }
        return actionServerAvailableValue
    }

    func destroyActionClient(_ client: any RclActionClientHandle) {
        guard let c = client as? MockRclActionClient else { return }
        c.markDestroyed()
        sync {
            actionClientsDestroyed.append((c.actionName, c.actionTypeName))
            teardownEvents.append("actionClient:\(c.actionName)")
        }
    }

    func graphPublishers(node: any RclNodeHandle) throws -> [RclGraphPublisherRecord] {
        let hook = sync { () -> (() -> Void)? in
            if let n = node as? MockRclNode { graphQueryNodes.append(n) }
            return onGraphPublishers
        }
        hook?()
        return try sync { () -> Result<[RclGraphPublisherRecord], any Error> in
            if let e = graphPublishersShouldThrow { return .failure(e) }
            return .success(graphRecords)
        }.get()
    }
}
