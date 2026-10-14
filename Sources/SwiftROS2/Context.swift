// Context.swift
// ROS 2 Context: entry point for the swift-ros2 library

import Foundation
import SwiftROS2Transport
import SwiftROS2Wire

// Absent where CycloneDDS is not consumable (Android; Windows without
// CYCLONEDDS_DIR): the manifest drops the DDS family there and `.dds`
// fails loudly in `makeDefaultSession`.
#if canImport(SwiftROS2DDS)
    import SwiftROS2DDS
#endif

// Absent when the zenoh-rmw RCL variant is selected (SWIFT_ROS2_RCL_RMW=zenoh):
// zenoh-pico and the variant's bundled zenoh-c export the same zenoh C API and
// cannot link into one binary, so the manifest carves the wire family out.
#if canImport(SwiftROS2Zenoh)
    import SwiftROS2Zenoh
#endif

#if SWIFT_ROS2_RCL
    import SwiftROS2RCL
#endif

/// ROS 2 context — the entry point for creating nodes
///
/// A context owns a single transport session. All nodes created from this context
/// share the session. Multiple contexts can coexist (e.g., Zenoh + DDS simultaneously)
/// on wire-path builds and on Apple RCL builds. On Linux RCL builds the rmw is
/// process-global (`RMW_IMPLEMENTATION` is selected once per process), so one process
/// serves one rmw at a time — mixing `.zenoh` and `.dds` contexts there is unsupported.
///
/// ```swift
/// let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/192.168.1.1:7447"))
/// let node = try await ctx.createNode(name: "my_node", namespace: "/ios")
/// ```
public final class ROS2Context: @unchecked Sendable {
    /// The transport configuration the session was opened with: the `transport`
    /// passed to the initializer, moved to the `domainId` argument when one was
    /// given.
    public let config: TransportConfig
    public let distro: ROS2Distro
    /// The ROS 2 domain the session runs on. Always equal to `config.domainId`.
    public let domainId: Int

    private let session: any TransportSession
    private let entityManager: EntityManager
    private let gidManager: GIDManager
    private var nodes: [ROS2Node] = []
    private let lock = NSLock()

    /// Runs this context's blocking teardown calls (entity, node and session
    /// closes) in order, off the cooperative thread pool. Its label is unique
    /// per context (`swift-ros2.context.<transport>.teardown.<n>`).
    let teardownQueue: TeardownQueue

    /// Create a new ROS 2 context
    ///
    /// The context runs on one ROS 2 domain. An explicit `domainId` wins over
    /// `transport.domainId`: the session is opened on `domainId` — the domain
    /// prefix of every wire Zenoh key expression, the CycloneDDS domain of the
    /// wire DDS participant, and the rcl context's domain on RCL. Unicast DDS
    /// peers on the discovery port of `transport.domainId` (for example
    /// `DDSPeer(address:)`'s default 7400 on domain 0) move to the discovery
    /// port of `domainId`; peers on any other port are kept. With `domainId`
    /// `nil` the transport's domain is used. ``config`` and ``domainId``
    /// report the domain the session was opened on.
    ///
    /// - Parameters:
    ///   - transport: Transport configuration (Zenoh, DDS, or RCL)
    ///   - distro: ROS 2 distribution for wire format (default: .jazzy)
    ///   - domainId: ROS 2 domain ID that overrides `transport.domainId`
    ///     (default: `nil`, use `transport.domainId`). Must be 0–232; opening
    ///     the session throws ``TransportError/invalidConfiguration(_:)`` otherwise.
    public convenience init(
        transport: TransportConfig,
        distro: ROS2Distro = .jazzy,
        domainId: Int? = nil
    ) async throws {
        try await self.init(
            transport: transport,
            distro: distro,
            domainId: domainId,
            session: nil
        )
    }

    /// Package-internal initializer for tests / custom transport sessions.
    package init(
        transport: TransportConfig,
        distro: ROS2Distro = .jazzy,
        domainId: Int? = nil,
        session: (any TransportSession)? = nil
    ) async throws {
        // An explicit domainId wins over the transport's: the session is made
        // and opened on the overridden configuration.
        let transport = domainId.map { transport.withDomainId($0) } ?? transport
        self.config = transport
        self.distro = distro
        self.domainId = transport.domainId
        self.entityManager = EntityManager()
        self.gidManager = GIDManager()
        self.teardownQueue = TeardownQueue(prefix: "swift-ros2.context.\(transport.type.rawValue).teardown")

        if let session = session {
            self.session = session
        } else {
            self.session = try Self.makeDefaultSession(for: transport)
        }

        if !self.session.isConnected {
            // The Zenoh wire depends on the distribution; an explicit
            // `wireMode` still wins.
            try await self.session.open(config: transport.withDefaultWireMode(distro))
        }
    }

    /// Create a node in this context.
    ///
    /// Preserves the pre-1.1 binary signature; delegates to the
    /// `options:`-aware overload with `ROS2NodeOptions.default`.
    public func createNode(
        name: String,
        namespace: String = "/"
    ) async throws -> ROS2Node {
        try await createNode(name: name, namespace: namespace, options: .default)
    }

    /// Create a node in this context with explicit per-node options.
    ///
    /// `options` has no default to avoid an overload-resolution
    /// ambiguity with the binary-stable `createNode(name:namespace:)`
    /// shim above. Pass `.default` to opt in to the standard behaviour
    /// (auto-register parameter services).
    public func createNode(
        name: String,
        namespace: String = "/",
        options: ROS2NodeOptions
    ) async throws -> ROS2Node {
        let nodeId = entityManager.getNextEntityId()
        let node = ROS2Node(
            name: name,
            namespace: namespace,
            context: self,
            session: session,
            nodeId: nodeId,
            entityManager: entityManager,
            gidManager: gidManager
        )
        // Let the transport create a real node where it models one (rcl).
        // Wire-level transports default to a no-op. On a later failure the
        // `catch` below calls node.destroy(), which unregisters it.
        try session.registerNode(name: name, namespace: namespace)
        if options.startParameterServices {
            // Register before the node is reachable from `shutdown` — if
            // any of the six createService calls throws, close the services
            // already created on this node before rethrowing so we don't
            // leak transport handles into the caller's hands.
            //
            // `startParameterServices()` also installs the /parameter_events
            // emitter, so the auto-start and manual-start paths leave the
            // node in the same observable state.
            do {
                try await node.startParameterServices()
            } catch {
                await node.destroy()
                throw error
            }
        }
        appendNode(node)
        return node
    }

    /// Shutdown the context and all nodes
    ///
    /// Destroys every node of the context in creation order (closing its
    /// entities, then unregistering it), then closes the session, and returns
    /// once all of that is done.
    ///
    /// The closes can block for as long as the transport stalls, for example a
    /// wire Zenoh close that waits for a put stuck on a frozen link. They run
    /// on a serial queue that belongs to this context, after any teardown of
    /// this context that started earlier, so they never hold a thread of the
    /// cooperative pool; the calling task suspends until they have finished.
    /// A stuck close in one context does not delay the shutdown of another.
    ///
    /// Do not block a swift-ros2 callback until a teardown of the same context
    /// finishes. If a close of that context that runs ahead of the teardown
    /// waits for the callback, as a publisher close does for an
    /// `onMatchedSubscriptionsChanged` handler call that is running, neither
    /// ever finishes.
    public func shutdown() async {
        await teardownQueue.run { [self] in
            for node in takeAllNodes() {
                node.closeEntitiesAndUnregister()
            }
            try? session.close()
        }
    }

    // MARK: - Private (synchronous lock helpers)

    private func appendNode(_ node: ROS2Node) {
        lock.lock()
        nodes.append(node)
        lock.unlock()
    }

    private func takeAllNodes() -> [ROS2Node] {
        lock.lock()
        let result = nodes
        nodes.removeAll()
        lock.unlock()
        return result
    }

    /// The session ID for debugging
    public var sessionId: String {
        session.sessionId
    }

    /// Whether the session is connected
    public var isConnected: Bool {
        session.isConnected
    }
}

// MARK: - Default Session Factory

extension ROS2Context {
    static func makeDefaultSession(for config: TransportConfig) throws -> any TransportSession {
        switch config.type {
        case .zenoh:
            #if os(Linux) && SWIFT_ROS2_RCL
                // Linux RCL: rmw selected at runtime (RMW_IMPLEMENTATION=rmw_zenoh_cpp,
                // set by RclClient from the zenoh locator). Wire zenoh-pico is still
                // linked (R1 = no collision) but RCL is preferred on Linux.
                return RclTransportSession(client: RclClient())
            #elseif canImport(SwiftROS2Zenoh)
                // Wire path (zenoh-pico) — every build except the zenoh-rmw variant.
                return ZenohTransportSession(client: ZenohClient())
            #elseif SWIFT_ROS2_RCL_RMW_ZENOH
                // zenoh-pico is carved out (symbol collision with the variant's
                // zenoh-c); `.zenoh` resolves to rcl + rmw_zenoh_cpp instead. The
                // router locator is plumbed through RclTransportSession.open.
                return RclTransportSession(client: RclClient())
            #else
                throw TransportError.unsupportedFeature(
                    "zenoh wire transport is carved out of the zenoh-rmw RCL build "
                        + "(SWIFT_ROS2_RCL_RMW=zenoh) — use .rcl, or build without the variant")
            #endif
        case .dds:
            #if os(Linux) && SWIFT_ROS2_RCL
                // Linux RCL: .dds resolves to rcl + rmw_cyclonedds_cpp (runtime rmw).
                return RclTransportSession(client: RclClient())
            #elseif canImport(SwiftROS2DDS)
                return DDSTransportSession(client: DDSClient())
            #else
                throw TransportError.unsupportedFeature(
                    "DDS is not available on this platform (no CycloneDDS in this build) "
                        + "— use .zenoh(locator:)")
            #endif
        case .rcl:
            #if SWIFT_ROS2_RCL_RMW_ZENOH
                // In the zenoh-rmw build the rcl stack speaks rmw_zenoh: a `.rcl`
                // (or `.rclUnicast`) config would open rmw_zenoh with default
                // session settings while exporting a meaningless CYCLONEDDS_URI —
                // none of its discovery knobs reach the wire. Reject it loudly.
                throw TransportError.unsupportedFeature(
                    ".rcl/.rclUnicast target rmw_cyclonedds and are unavailable in the "
                        + "zenoh-rmw build (SWIFT_ROS2_RCL_RMW=zenoh) — use .zenoh(locator:) "
                        + "(the RCL transport in this build) or .dds (wire CycloneDDS)")
            #elseif SWIFT_ROS2_RCL
                return RclTransportSession(client: RclClient())
            #else
                throw TransportError.unsupportedFeature(
                    "rcl backend not built — on Apple it is built by default (unset "
                        + "SWIFT_ROS2_DISABLE_RCL); on Linux set SWIFT_ROS2_ENABLE_RCL=1 "
                        + "(system ROS 2); Windows and Android have no rcl backend")
            #endif
        }
    }
}
