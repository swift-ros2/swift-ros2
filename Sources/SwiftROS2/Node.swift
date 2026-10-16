// Node.swift
// ROS 2 Node: creates publishers, subscribers, services, and actions

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2Transport
import SwiftROS2Wire

/// ROS 2 node — owns publishers, subscribers, services, and actions
///
/// ```swift
/// let node = try await ctx.createNode(name: "sensor_node", namespace: "/ios")
/// let pub = try await node.createPublisher(Imu.self, topic: "imu")
/// let sub = try await node.createSubscription(Imu.self, topic: "imu")
/// ```
public final class ROS2Node: @unchecked Sendable {
    public let name: String
    public let namespace: String
    public let fullyQualifiedName: String

    let context: ROS2Context
    private let session: any TransportSession

    private var entities: [any NodeEntity] = []
    private let lock = NSLock()

    let parameterStore: ParameterStore = ParameterStore()
    private var parameterEventPublisher: ROS2Publisher<ParameterEvent>?
    private var parameterEventPublisherTask: Task<ROS2Publisher<ParameterEvent>, Error>?

    init(name: String, namespace: String, context: ROS2Context, session: any TransportSession) {
        self.name = name
        self.namespace = namespace
        self.fullyQualifiedName = namespace.hasSuffix("/") ? "\(namespace)\(name)" : "\(namespace)/\(name)"
        self.context = context
        self.session = session
    }

    // MARK: - Publisher

    /// Create a publisher for a message type
    public func createPublisher<M: CDREncodable & ROS2MessageType>(
        _ messageType: M.Type,
        topic: String,
        qos: QoSProfile = .sensorData
    ) async throws -> ROS2Publisher<M> {
        let fullTopic = buildFullTopic(topic)
        let typeInfo = M.typeInfo
        let transportQoS = qos.toTransportQoS()
        let effectiveTypeHash = context.distro.supportsTypeHash ? typeInfo.typeHash : nil

        let transportPub: any TransportPublisher
        if let scoped = session as? NodeScopedSession {
            transportPub = try scoped.createPublisher(
                topic: fullTopic,
                typeName: typeInfo.typeName,
                typeHash: effectiveTypeHash,
                qos: transportQoS,
                nodeName: name,
                nodeNamespace: namespace
            )
        } else {
            transportPub = try session.createPublisher(
                topic: fullTopic,
                typeName: typeInfo.typeName,
                typeHash: effectiveTypeHash,
                qos: transportQoS
            )
        }

        let publisher = ROS2Publisher<M>(
            transportPublisher: transportPub,
            isLegacySchema: context.distro.isLegacySchema
        )
        append(publisher)
        return publisher
    }

    // MARK: - Subscription

    /// Create a subscription for a message type (AsyncStream-based)
    ///
    /// The subscription uses ``SubscriptionDelivery/stream``; attach a handler with
    /// ``ROS2Subscription/onMessage(_:)`` or iterate ``ROS2Subscription/messages``.
    public func createSubscription<M: CDRDecodable & ROS2MessageType>(
        _ messageType: M.Type,
        topic: String,
        qos: QoSProfile = .sensorData
    ) async throws -> ROS2Subscription<M> {
        try makeSubscription(messageType, topic: topic, qos: qos, delivery: .stream, handler: nil)
    }

    /// Creates a subscription with the given delivery mode.
    ///
    /// With `.stream` this is ``createSubscription(_:topic:qos:)``. With `.latestOnly`,
    /// attach the handler with ``ROS2Subscription/onMessage(_:)``; the newest message
    /// that arrived before that is delivered once the handler is set.
    public func createSubscription<M: CDRDecodable & ROS2MessageType>(
        _ type: M.Type, topic: String, qos: QoSProfile, delivery: SubscriptionDelivery
    ) async throws -> ROS2Subscription<M> {
        try makeSubscription(type, topic: topic, qos: qos, delivery: delivery, handler: nil)
    }

    /// Creates a subscription whose handler is attached before the transport subscriber
    /// exists, so no message is missed between creation and attachment, including a
    /// transient-local sample replayed during creation.
    ///
    /// With `.stream` the handler runs on the transport's receive thread after the message
    /// is yielded into ``ROS2Subscription/messages``, which still buffers the newest 100
    /// messages whether or not anyone reads it. With `.latestOnly` it runs on the
    /// subscription's delivery queue, never concurrently with itself, newest message only.
    /// ``ROS2Subscription/onMessage(_:)`` replaces the handler.
    public func createSubscription<M: CDRDecodable & ROS2MessageType>(
        _ type: M.Type, topic: String, qos: QoSProfile, delivery: SubscriptionDelivery,
        handler: @escaping @Sendable (M) -> Void
    ) async throws -> ROS2Subscription<M> {
        try makeSubscription(type, topic: topic, qos: qos, delivery: delivery, handler: handler)
    }

    /// The one implementation behind the three `createSubscription` overloads. The
    /// subscription, with its delivery mode and handler, exists before the transport
    /// subscriber, so a sample delivered during `createSubscriber` finds the handler.
    private func makeSubscription<M: CDRDecodable & ROS2MessageType>(
        _ messageType: M.Type,
        topic: String,
        qos: QoSProfile,
        delivery: SubscriptionDelivery,
        handler userHandler: (@Sendable (M) -> Void)?
    ) throws -> ROS2Subscription<M> {
        let fullTopic = buildFullTopic(topic)
        let typeInfo = M.typeInfo
        var transportQoS = qos.toTransportQoS()
        if delivery == .latestOnly {
            // The mailbox keeps one message, so the reader needs only one. History depth is not
            // a matching policy; reliability and durability pass through.
            transportQoS = TransportQoS(
                reliability: transportQoS.reliability,
                durability: transportQoS.durability,
                history: .keepLast(1)
            )
        }
        let effectiveTypeHash = context.distro.supportsTypeHash ? typeInfo.typeHash : nil

        let subscription = ROS2Subscription<M>(
            topic: fullTopic,
            delivery: delivery,
            handler: userHandler,
            isLegacySchema: context.distro.isLegacySchema
        )

        let handler: @Sendable (Data, UInt64) -> Void = { [weak subscription] data, _ in
            subscription?.receivePayload(data)
        }

        let transportSub: any TransportSubscriber
        if let scoped = session as? NodeScopedSession {
            transportSub = try scoped.createSubscriber(
                topic: fullTopic,
                typeName: typeInfo.typeName,
                typeHash: effectiveTypeHash,
                qos: transportQoS,
                nodeName: name,
                nodeNamespace: namespace,
                handler: handler
            )
        } else {
            transportSub = try session.createSubscriber(
                topic: fullTopic,
                typeName: typeInfo.typeName,
                typeHash: effectiveTypeHash,
                qos: transportQoS,
                handler: handler
            )
        }

        subscription.setTransportSubscriber(transportSub)
        append(subscription)
        return subscription
    }

    // MARK: - Service

    /// Create a service server for a specific ``ROS2ServiceType``.
    ///
    /// The handler closure receives a typed request and returns a typed
    /// response. Throwing from the handler surfaces to the caller as a
    /// ``ServiceError/handlerFailed(_:)`` (Zenoh) or as a dropped reply
    /// (DDS) — see the swift-ros2 docs for the per-transport contract.
    public func createService<S: ROS2ServiceType>(
        _ serviceType: S.Type,
        name: String,
        qos: QoSProfile = .servicesDefault,
        handler: @escaping @Sendable (S.Request) async throws -> S.Response
    ) async throws -> ROS2Service<S> {
        let fullName = buildFullTopic(name)
        let typeInfo = S.typeInfo
        let transportQoS = qos.toTransportQoS()
        let supportsHash = context.distro.supportsTypeHash
        let isLegacy = context.distro.isLegacySchema
        let requestHash = supportsHash ? typeInfo.requestTypeHash : nil
        let responseHash = supportsHash ? typeInfo.responseTypeHash : nil
        let serviceHash = supportsHash ? typeInfo.serviceTypeHash : nil

        // Wrap the typed user handler in a CDR-bytes handler the transport
        // can call without knowing about S.Request / S.Response.
        let cdrHandler: @Sendable (Data) async throws -> Data = { reqData in
            let decoder: CDRDecoder
            do {
                decoder = try CDRDecoder(data: reqData, isLegacySchema: isLegacy)
            } catch {
                throw ServiceError.requestDecodingFailed(error.localizedDescription)
            }
            let typedRequest: S.Request
            do {
                typedRequest = try S.Request(from: decoder)
            } catch {
                throw ServiceError.requestDecodingFailed(error.localizedDescription)
            }
            let typedResponse = try await handler(typedRequest)
            let encoder = CDREncoder(isLegacySchema: isLegacy)
            encoder.writeEncapsulationHeader()
            do {
                try typedResponse.encode(to: encoder)
            } catch {
                throw ServiceError.responseEncodingFailed(error.localizedDescription)
            }
            return encoder.getData()
        }

        let transportSvc: any TransportService
        if let scoped = session as? NodeScopedSession {
            transportSvc = try scoped.createServiceServer(
                name: fullName,
                serviceTypeName: typeInfo.serviceName,
                requestTypeHash: requestHash,
                responseTypeHash: responseHash,
                serviceTypeHash: serviceHash,
                qos: transportQoS,
                nodeName: self.name,
                nodeNamespace: namespace,
                handler: cdrHandler
            )
        } else {
            transportSvc = try session.createServiceServer(
                name: fullName,
                serviceTypeName: typeInfo.serviceName,
                requestTypeHash: requestHash,
                responseTypeHash: responseHash,
                qos: transportQoS,
                handler: cdrHandler
            )
        }

        let service = ROS2Service<S>(transport: transportSvc)
        append(service)
        return service
    }

    /// Create a service client for a specific ``ROS2ServiceType``.
    public func createClient<S: ROS2ServiceType>(
        _ serviceType: S.Type,
        name: String,
        qos: QoSProfile = .servicesDefault
    ) async throws -> ROS2Client<S> {
        let fullName = buildFullTopic(name)
        let typeInfo = S.typeInfo
        let transportQoS = qos.toTransportQoS()
        let supportsHash = context.distro.supportsTypeHash
        let requestHash = supportsHash ? typeInfo.requestTypeHash : nil
        let responseHash = supportsHash ? typeInfo.responseTypeHash : nil
        let serviceHash = supportsHash ? typeInfo.serviceTypeHash : nil

        let transportClient: any TransportClient
        if let scoped = session as? NodeScopedSession {
            transportClient = try scoped.createServiceClient(
                name: fullName,
                serviceTypeName: typeInfo.serviceName,
                requestTypeHash: requestHash,
                responseTypeHash: responseHash,
                serviceTypeHash: serviceHash,
                qos: transportQoS,
                nodeName: self.name,
                nodeNamespace: namespace
            )
        } else {
            transportClient = try session.createServiceClient(
                name: fullName,
                serviceTypeName: typeInfo.serviceName,
                requestTypeHash: requestHash,
                responseTypeHash: responseHash,
                qos: transportQoS
            )
        }

        let client = ROS2Client<S>(
            transport: transportClient,
            isLegacySchema: context.distro.isLegacySchema
        )
        append(client)
        return client
    }

    // MARK: - Action

    /// Create an action server for a specific ``ROS2Action``.
    public func createActionServer<H: ActionServerHandler>(
        _ actionType: H.Action.Type,
        name: String,
        qos: QoSProfile = .actionDefault,
        handler: H
    ) async throws -> ROS2ActionServer<H> {
        let fullName = buildFullTopic(name)
        let typeInfo = H.Action.typeInfo
        let transportQoS = qos.toTransportQoS()
        let hashes = roleTypeHashes(typeInfo)

        let serverHolder = WeakHolder<ROS2ActionServer<H>>()
        let handlers = ROS2ActionServer<H>.makeHandlers(
            isLegacySchema: context.distro.isLegacySchema
        ) { serverHolder.value }
        let transportServer: any TransportActionServer
        if let scoped = session as? NodeScopedSession {
            transportServer = try scoped.createActionServer(
                name: fullName,
                actionTypeName: typeInfo.actionName,
                roleTypeHashes: hashes,
                qos: transportQoS,
                nodeName: self.name,
                nodeNamespace: namespace,
                handlers: handlers
            )
        } else {
            transportServer = try session.createActionServer(
                name: fullName,
                actionTypeName: typeInfo.actionName,
                roleTypeHashes: hashes,
                qos: transportQoS,
                handlers: handlers
            )
        }
        let server = ROS2ActionServer<H>(
            transport: transportServer,
            handler: handler,
            isLegacySchema: context.distro.isLegacySchema
        )
        serverHolder.value = server
        append(server)
        return server
    }

    /// Create an action client for a specific ``ROS2Action``.
    public func createActionClient<A: ROS2Action>(
        _ actionType: A.Type,
        name: String,
        qos: QoSProfile = .actionDefault
    ) async throws -> ROS2ActionClient<A> {
        let fullName = buildFullTopic(name)
        let typeInfo = A.typeInfo
        let transportQoS = qos.toTransportQoS()
        let hashes = roleTypeHashes(typeInfo)

        let transportClient: any TransportActionClient
        if let scoped = session as? NodeScopedSession {
            transportClient = try scoped.createActionClient(
                name: fullName,
                actionTypeName: typeInfo.actionName,
                roleTypeHashes: hashes,
                qos: transportQoS,
                nodeName: self.name,
                nodeNamespace: namespace
            )
        } else {
            transportClient = try session.createActionClient(
                name: fullName,
                actionTypeName: typeInfo.actionName,
                roleTypeHashes: hashes,
                qos: transportQoS
            )
        }
        let client = ROS2ActionClient<A>(
            transport: transportClient,
            isLegacySchema: context.distro.isLegacySchema
        )
        append(client)
        return client
    }

    // MARK: - Lifecycle

    /// Destroy this node and release all resources
    ///
    /// Closes the node's publishers, subscriptions, services, clients, action
    /// servers and action clients, then unregisters the node, and returns once
    /// all of that is done.
    ///
    /// Like ``ROS2Context/shutdown()``, the closes run on the context's serial
    /// teardown queue, after any teardown of the context that started earlier,
    /// so a close that blocks on a stalled transport never holds a thread of
    /// the cooperative pool.
    ///
    /// Do not block a swift-ros2 callback until a teardown of the same context
    /// finishes. If a close of that context that runs ahead of the teardown
    /// waits for the callback, as a publisher close does for an
    /// `onMatchedSubscriptionsChanged` handler call that is running, neither
    /// ever finishes.
    public func destroy() async {
        await context.teardownQueue.run { [self] in
            closeEntitiesAndUnregister()
        }
    }

    /// Closes every entity of the node, then unregisters it.
    ///
    /// Blocking: the transport calls run on the calling thread. Only called on
    /// the context's teardown queue, by ``destroy()`` and
    /// ``ROS2Context/shutdown()``, which the precondition enforces.
    func closeEntitiesAndUnregister() {
        context.teardownQueue.assertOnQueue()
        // Kind by kind (publishers, subscriptions, services, clients, action
        // servers, action clients), each kind in creation order.
        let taken = takeAllEntities()
        for kind in NodeEntityKind.allCases {
            for entity in taken where entity.nodeEntityKind == kind {
                try? entity.closeEntity()
            }
        }
        session.unregisterNode(name: name, namespace: namespace)
    }

    // MARK: - Private (synchronous lock helpers)

    private func append(_ entity: any NodeEntity) {
        lock.lock()
        entities.append(entity)
        lock.unlock()
    }

    private func takeAllEntities() -> [any NodeEntity] {
        lock.lock()
        let taken = entities
        entities.removeAll()
        lock.unlock()
        return taken
    }

    // MARK: - Helpers

    /// The per-role type hashes of an action: the ones `typeInfo` carries and the
    /// fixed `action_msgs` ones, or none on a distribution without type hashes.
    private func roleTypeHashes(_ typeInfo: ROS2ActionTypeInfo) -> ActionRoleTypeHashes {
        let supportsHash = context.distro.supportsTypeHash
        return ActionRoleTypeHashes(
            sendGoalRequest: supportsHash ? typeInfo.sendGoalRequestTypeHash : nil,
            sendGoalResponse: supportsHash ? typeInfo.sendGoalResponseTypeHash : nil,
            cancelGoalRequest: supportsHash ? CancelGoalSrv.typeInfo.requestTypeHash : nil,
            cancelGoalResponse: supportsHash ? CancelGoalSrv.typeInfo.responseTypeHash : nil,
            getResultRequest: supportsHash ? typeInfo.getResultRequestTypeHash : nil,
            getResultResponse: supportsHash ? typeInfo.getResultResponseTypeHash : nil,
            feedbackMessage: supportsHash ? typeInfo.feedbackMessageTypeHash : nil,
            statusArray: supportsHash ? GoalStatusArray.typeInfo.typeHash : nil,
            sendGoalService: supportsHash ? typeInfo.sendGoalServiceTypeHash : nil,
            cancelGoalService: supportsHash ? CancelGoalSrv.typeInfo.serviceTypeHash : nil,
            getResultService: supportsHash ? typeInfo.getResultServiceTypeHash : nil
        )
    }

    private func buildFullTopic(_ topic: String) -> String {
        if topic.hasPrefix("/") {
            return topic
        }
        let ns = namespace.hasSuffix("/") ? namespace : namespace + "/"
        return "\(ns)\(topic)"
    }
}

extension ROS2Node {
    /// Installs the per-node emitter so the store's `declare` / `set*` /
    /// `undeclare` operations route the resulting `ParameterEvent` out the
    /// `/parameter_events` topic. Called from `startParameterServices()`
    /// so the emitter is wired whether the node was created with
    /// `ROS2NodeOptions.startParameterServices = true` (auto-start path)
    /// or whether the caller opted out and later invoked
    /// `node.startParameterServices()` manually.
    internal func installParameterEventEmitter() async {
        let fqn = self.fullyQualifiedName
        await parameterStore.setEventEmitter { [weak self] event in
            guard let self = self else { return }
            var stamped = event
            stamped.node = fqn
            Task { await self.dispatchParameterEvent(stamped) }
        }
    }

    /// Lazily creates the `/parameter_events` publisher on first emission
    /// and forwards the event. The publisher is appended to `publishers`
    /// so `destroy()` closes it like any other.
    private func dispatchParameterEvent(_ event: ParameterEvent) async {
        do {
            let pub = try await ensureParameterEventPublisher()
            try pub.publish(event)
        } catch {
            // Silent drop: emitting a parameter event must never throw out
            // of a parameter mutation. The store has already committed.
        }
    }

    /// Single-flight publisher creation. Concurrent callers share the same
    /// in-flight `Task`, so `createPublisher` runs at most once and we
    /// never end up with a "loser" publisher leaked into `publishers`.
    private func ensureParameterEventPublisher() async throws -> ROS2Publisher<ParameterEvent> {
        // Fast path: already created.
        lock.lock()
        if let p = parameterEventPublisher {
            lock.unlock()
            return p
        }
        // Slow path: piggyback on an in-flight creation if one is running,
        // otherwise become the creator.
        if let inflight = parameterEventPublisherTask {
            lock.unlock()
            return try await inflight.value
        }
        let task = Task<ROS2Publisher<ParameterEvent>, Error> { [weak self] in
            guard let self = self else { throw ParameterEventPublisherError.nodeDeallocated }
            return try await self.createPublisher(
                ParameterEvent.self,
                topic: "/parameter_events",
                qos: .parameterEvents
            )
        }
        parameterEventPublisherTask = task
        lock.unlock()

        do {
            let pub = try await task.value
            lock.lock()
            parameterEventPublisher = pub
            parameterEventPublisherTask = nil
            lock.unlock()
            return pub
        } catch {
            lock.lock()
            parameterEventPublisherTask = nil
            lock.unlock()
            throw error
        }
    }
}

private enum ParameterEventPublisherError: Error {
    case nodeDeallocated
}

/// The kinds of entity a node owns, in the order its teardown closes them.
enum NodeEntityKind: CaseIterable {
    case publisher, subscription, service, client, actionServer, actionClient
}

/// An entity a ``ROS2Node`` owns and closes when the node is destroyed.
protocol NodeEntity: AnyObject {
    var nodeEntityKind: NodeEntityKind { get }
    func closeEntity() throws
}
