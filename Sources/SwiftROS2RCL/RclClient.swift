// RclClient.swift
// Concrete RclClientProtocol over the CRclBridge C FFI. Built on Apple by
// default (prebuilt xcframework, rmw baked per build variant; opt out with
// SWIFT_ROS2_DISABLE_RCL=1) and on Linux with SWIFT_ROS2_ENABLE_RCL=1 (system
// ROS 2 install, rmw selected at runtime).

import CDDSBridge
import CRclBridge
import Foundation
import SwiftROS2Transport
import SwiftROS2Wire

// MARK: - Handles

private final class RclNodeBox: RclNodeHandle, @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ ptr: OpaquePointer) { self.ptr = ptr }
}

/// Collects the publishers `crcl_graph_snapshot` reports. Only touched on the
/// thread that runs the snapshot (the callback is synchronous).
private final class RclGraphCollector {
    var records: [RclGraphPublisherRecord] = []
}

/// C-callable bridge matching `crcl_graph_publisher_callback_t`. `ctx` is an
/// unretained `RclGraphCollector` kept alive by `graphPublishers(node:)` for the
/// duration of the snapshot; the strings are copied before the call returns.
private func rclGraphPublisherCallbackBridge(
    ctx: UnsafeMutableRawPointer?,
    topicName: UnsafePointer<CChar>?,
    topicType: UnsafePointer<CChar>?,
    reliability: Int32,
    durability: Int32,
    nodeName: UnsafePointer<CChar>?,
    nodeNamespace: UnsafePointer<CChar>?
) {
    guard let ctx, let topicName else { return }
    let collector = Unmanaged<RclGraphCollector>.fromOpaque(ctx).takeUnretainedValue()
    collector.records.append(
        RclGraphPublisherRecord(
            topicName: String(cString: topicName),
            typeName: topicType.map { String(cString: $0) } ?? "",
            reliability: reliability,
            durability: durability,
            nodeName: nodeName.map { String(cString: $0) } ?? "",
            nodeNamespace: nodeNamespace.map { String(cString: $0) } ?? ""))
}

/// Per-box lock serializes destroy vs. publish on the same publisher pointer.
final class RclPublisherBox: RclPublisherHandle, @unchecked Sendable {
    private var ptr: OpaquePointer?
    private let lock = NSLock()

    init(_ ptr: OpaquePointer) { self.ptr = ptr }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ptr != nil
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let p = ptr {
            crcl_publisher_destroy(p)
            ptr = nil
        }
    }

    func withPtr<R>(_ body: (OpaquePointer) -> R) -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = ptr else { return nil }
        return body(p)
    }
}

/// Route-(b) publisher handle for non-bundled (registry-miss) types. Wraps a
/// `CDDSBridge` raw-CDR writer on a sibling CycloneDDS participant — published
/// below rmw, so it is outside rcl's entity graph but interoperable with any
/// ROS 2 subscriber by topic name + DDS type name. The same machinery the
/// pure-Swift DDS backend ships. Per-box lock serializes destroy vs. write.
final class RclRawPublisherBox: RclPublisherHandle, @unchecked Sendable {
    private let writer: OpaquePointer
    private let lock = NSLock()
    private var closed = false
    init(writer: OpaquePointer) { self.writer = writer }
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            dds_bridge_destroy_writer(writer)
        }
    }
    /// Write pre-serialized CDR below rmw. Returns the dds_bridge_write_raw_cdr
    /// status (0 success, negative failure), or nil if the box is already
    /// closed. Locked so a concurrent close() cannot free the writer mid-write.
    func write(_ data: Data) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            // 0 ⇒ CycloneDDS source-stamps the sample.
            return dds_bridge_write_raw_cdr(writer, base, data.count, 0)
        }
    }
    /// Matched subscriptions of the raw writer, or nil when closed or unknown.
    func matchedCount() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        let n = dds_bridge_writer_matched_count(writer)
        return n >= 0 ? Int(n) : nil
    }
}

/// Retained by `RclSubscriptionBox.contextBox` while the subscription is
/// alive. The `@unchecked Sendable` is justified: the class holds an
/// immutable `@Sendable` closure reference; the closure captures are the only
/// state shared across threads, and Swift's concurrency model already
/// requires those to be Sendable.
private final class RclSubscriptionContext: @unchecked Sendable {
    let handler: @Sendable (Data, UInt64) -> Void
    init(handler: @escaping @Sendable (Data, UInt64) -> Void) {
        self.handler = handler
    }
}

/// C-callable bridge matching `crcl_take_callback_t`.
/// The `ctx` pointer is an `Unmanaged<RclSubscriptionContext>` opaque pointer
/// created via `passRetained` in `createSubscription`; here we only borrow it
/// (`takeUnretainedValue`) — retention is released in `RclSubscriptionBox.close()`.
private func rclTakeCallbackBridge(
    ctx: UnsafeMutableRawPointer?,
    buf: UnsafePointer<UInt8>?,
    len: Int,
    sourceTimestampNs: Int64
) {
    guard let ctx else { return }
    let subscriptionContext = Unmanaged<RclSubscriptionContext>.fromOpaque(ctx).takeUnretainedValue()

    let payload: Data
    if let buf, len > 0 {
        payload = Data(bytes: buf, count: len)
    } else {
        payload = Data()
    }

    subscriptionContext.handler(payload, sourceTimestampNs > 0 ? UInt64(sourceTimestampNs) : 0)
}

/// Per-box lock serializes destroy vs. isActive checks for the same
/// subscription. Different subscriptions hold different locks.
private final class RclSubscriptionBox: RclSubscriptionHandle, @unchecked Sendable {
    private var ptr: OpaquePointer?
    private var contextBox: Unmanaged<RclSubscriptionContext>?
    private let lock = NSLock()

    init(_ ptr: OpaquePointer, contextBox: Unmanaged<RclSubscriptionContext>) {
        self.ptr = ptr
        self.contextBox = contextBox
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ptr != nil
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let p = ptr {
            // crcl_subscription_destroy joins the wait thread before any fini,
            // so it blocks until any in-flight callback has returned. Only
            // after it returns is it safe to release the retained closure
            // context, because no further callback invocations will
            // dereference it.
            let rc = crcl_subscription_destroy(p)
            ptr = nil
            if rc < 0 {
                // The C side refused to destroy (self-destroy from the take
                // callback, or a failed join): the wait thread may still
                // invoke the callback, so the retained handler context must
                // leak alongside the C subscription rather than be released
                // under a live thread.
                contextBox = nil
                return
            }
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }
}

/// C-callable bridge matching `dds_bridge_data_callback_t` for route-(b) raw
/// readers. Borrows the `Unmanaged<RclSubscriptionContext>` (passRetained in
/// `createRawReaderSubscription`); retention is released in
/// `RclRawSubscriptionBox.close()`.
private func rclRawReaderCallbackBridge(
    cdrData: UnsafePointer<UInt8>?,
    cdrLen: Int,
    timestampNs: UInt64,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let subscriptionContext =
        Unmanaged<RclSubscriptionContext>.fromOpaque(context).takeUnretainedValue()
    let payload: Data
    if let cdrData, cdrLen > 0 {
        payload = Data(bytes: cdrData, count: cdrLen)
    } else {
        payload = Data()
    }
    subscriptionContext.handler(payload, timestampNs)
}

/// Route-(b) subscription handle for non-bundled (registry-miss) types. Wraps a
/// `CDDSBridge` raw-CDR reader on the sibling CycloneDDS participant — received
/// below rmw, outside rcl's wait-set but interoperable with any ROS 2 publisher
/// by topic name + DDS type name. The mirror of `RclRawPublisherBox`; the same
/// machinery the pure-Swift DDS backend ships.
private final class RclRawSubscriptionBox: RclSubscriptionHandle, @unchecked Sendable {
    private var reader: OpaquePointer?
    private var contextBox: Unmanaged<RclSubscriptionContext>?
    private let lock = NSLock()
    init(reader: OpaquePointer, contextBox: Unmanaged<RclSubscriptionContext>) {
        self.reader = reader
        self.contextBox = contextBox
    }
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let r = reader else { return false }
        return dds_bridge_reader_is_active(r)
    }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let r = reader {
            // dds_bridge_destroy_reader blocks until any in-flight callback
            // returns (CycloneDDS contract); only then is releasing the retained
            // closure context safe.
            dds_bridge_destroy_reader(r)
            reader = nil
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }
}

// MARK: - Service server

/// Retained by `RclServiceBox.contextBox` while the service is alive. Same
/// `@unchecked Sendable` justification as `RclSubscriptionContext`: the only
/// state is an immutable `@Sendable` closure reference.
private final class RclServiceContext: @unchecked Sendable {
    let onRequest: @Sendable (Data, [UInt8]) -> Void
    init(onRequest: @escaping @Sendable (Data, [UInt8]) -> Void) {
        self.onRequest = onRequest
    }
}

/// C-callable bridge matching `crcl_request_callback_t`.
/// The `ctx` pointer is an `Unmanaged<RclServiceContext>` opaque pointer
/// created via `passRetained` in `createServiceServer`; here we only borrow it
/// (`takeUnretainedValue`) — retention is released in `RclServiceBox.close()`.
private func rclRequestCallbackBridge(
    ctx: UnsafeMutableRawPointer?,
    requestId: UnsafePointer<UInt8>?,
    buf: UnsafePointer<UInt8>?,
    len: Int
) {
    guard let ctx, let requestId else { return }
    let serviceContext = Unmanaged<RclServiceContext>.fromOpaque(ctx).takeUnretainedValue()

    let blob = [UInt8](UnsafeBufferPointer(start: requestId, count: Int(CRCL_REQUEST_ID_SIZE)))
    let payload: Data
    if let buf, len > 0 {
        payload = Data(bytes: buf, count: len)
    } else {
        payload = Data()
    }

    serviceContext.onRequest(payload, blob)
}

/// Per-box lock serializes destroy vs. sendResponse on the same service
/// pointer. Close contract mirrors `RclSubscriptionBox` exactly, including the
/// leak-on-failed-destroy behavior.
private final class RclServiceBox: RclServiceHandle, @unchecked Sendable {
    private var ptr: OpaquePointer?
    private var contextBox: Unmanaged<RclServiceContext>?
    private let lock = NSLock()

    init(_ ptr: OpaquePointer, contextBox: Unmanaged<RclServiceContext>) {
        self.ptr = ptr
        self.contextBox = contextBox
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ptr != nil
    }

    func withPtr<R>(_ body: (OpaquePointer) -> R) -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = ptr else { return nil }
        return body(p)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let p = ptr {
            // crcl_service_destroy joins the wait thread before any fini, so
            // it blocks until any in-flight callback has returned. Only after
            // it returns is it safe to release the retained closure context.
            let rc = crcl_service_destroy(p)
            ptr = nil
            if rc < 0 {
                // The C side refused to destroy (self-destroy from the take
                // callback, or a failed join): the wait thread may still
                // invoke the callback, so the retained handler context must
                // leak alongside the C service rather than be released under
                // a live thread.
                contextBox = nil
                return
            }
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }
}

// MARK: - Service client

/// Retained by `RclServiceClientBox.contextBox` while the client is alive.
private final class RclServiceClientContext: @unchecked Sendable {
    let onResponse: @Sendable (Int64, Data) -> Void
    init(onResponse: @escaping @Sendable (Int64, Data) -> Void) {
        self.onResponse = onResponse
    }
}

/// C-callable bridge matching `crcl_response_callback_t`. Same Unmanaged
/// borrow contract as `rclRequestCallbackBridge`.
private func rclResponseCallbackBridge(
    ctx: UnsafeMutableRawPointer?,
    sequenceNumber: Int64,
    buf: UnsafePointer<UInt8>?,
    len: Int
) {
    guard let ctx else { return }
    let clientContext = Unmanaged<RclServiceClientContext>.fromOpaque(ctx).takeUnretainedValue()

    let payload: Data
    if let buf, len > 0 {
        payload = Data(bytes: buf, count: len)
    } else {
        payload = Data()
    }

    clientContext.onResponse(sequenceNumber, payload)
}

/// Per-box lock serializes destroy vs. sendRequest / serverAvailable on the
/// same client pointer. Close contract mirrors `RclSubscriptionBox` exactly,
/// including the leak-on-failed-destroy behavior.
private final class RclServiceClientBox: RclClientHandle, @unchecked Sendable {
    private var ptr: OpaquePointer?
    private var contextBox: Unmanaged<RclServiceClientContext>?
    private let lock = NSLock()

    init(_ ptr: OpaquePointer, contextBox: Unmanaged<RclServiceClientContext>) {
        self.ptr = ptr
        self.contextBox = contextBox
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ptr != nil
    }

    func withPtr<R>(_ body: (OpaquePointer) -> R) -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = ptr else { return nil }
        return body(p)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let p = ptr {
            // crcl_client_destroy joins the wait thread before any fini, so
            // it blocks until any in-flight callback has returned.
            let rc = crcl_client_destroy(p)
            ptr = nil
            if rc < 0 {
                // Refused destroy — leak the retained handler context rather
                // than release it under a live thread.
                contextBox = nil
                return
            }
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }
}

// MARK: - Action server

/// Retained by `RclActionServerBox.contextBox` while the action server is
/// alive. Same `@unchecked Sendable` justification as `RclSubscriptionContext`:
/// the only state is an immutable `Sendable` callback bag.
private final class RclActionServerContext: @unchecked Sendable {
    let callbacks: RclActionServerCallbacks
    init(callbacks: RclActionServerCallbacks) {
        self.callbacks = callbacks
    }
}

/// C-callable bridge matching `crcl_action_server_callback_t`. Same Unmanaged
/// borrow contract as `rclRequestCallbackBridge`; the `role` discriminates the
/// three request kinds.
private func rclActionServerCallbackBridge(
    ctx: UnsafeMutableRawPointer?,
    role: Int32,
    requestId: UnsafePointer<UInt8>?,
    buf: UnsafePointer<UInt8>?,
    len: Int
) {
    guard let ctx, let requestId else { return }
    let serverContext = Unmanaged<RclActionServerContext>.fromOpaque(ctx).takeUnretainedValue()

    let blob = [UInt8](UnsafeBufferPointer(start: requestId, count: Int(CRCL_REQUEST_ID_SIZE)))
    let payload: Data
    if let buf, len > 0 {
        payload = Data(bytes: buf, count: len)
    } else {
        payload = Data()
    }

    switch role {
    case CRCL_ACTION_SERVER_GOAL_REQUEST:
        serverContext.callbacks.onGoalRequest(payload, blob)
    case CRCL_ACTION_SERVER_CANCEL_REQUEST:
        serverContext.callbacks.onCancelRequest(payload, blob)
    case CRCL_ACTION_SERVER_RESULT_REQUEST:
        serverContext.callbacks.onResultRequest(payload, blob)
    default:
        break
    }
}

/// Per-box lock serializes destroy vs. send / publish / goal bookkeeping on
/// the same action server pointer. Close contract mirrors `RclServiceBox`
/// exactly, including the leak-on-failed-destroy behavior.
private final class RclActionServerBox: RclActionServerHandle, @unchecked Sendable {
    private var ptr: OpaquePointer?
    private var contextBox: Unmanaged<RclActionServerContext>?
    private let lock = NSLock()

    init(_ ptr: OpaquePointer, contextBox: Unmanaged<RclActionServerContext>) {
        self.ptr = ptr
        self.contextBox = contextBox
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ptr != nil
    }

    func withPtr<R>(_ body: (OpaquePointer) -> R) -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = ptr else { return nil }
        return body(p)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let p = ptr {
            // crcl_action_server_destroy joins the wait thread before any
            // fini, so it blocks until any in-flight callback has returned.
            let rc = crcl_action_server_destroy(p)
            ptr = nil
            if rc < 0 {
                // Refused destroy — leak the retained handler context rather
                // than release it under a live thread.
                contextBox = nil
                return
            }
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }
}

// MARK: - Action client

/// Retained by `RclActionClientBox.contextBox` while the action client is alive.
private final class RclActionClientContext: @unchecked Sendable {
    let callbacks: RclActionClientCallbacks
    init(callbacks: RclActionClientCallbacks) {
        self.callbacks = callbacks
    }
}

/// Parse the flattened status records the C bridge emits for
/// CRCL_ACTION_CLIENT_STATUS (see CRCL_GOAL_STATUS_RECORD_SIZE).
private func rclParseStatusRecords(buf: UnsafePointer<UInt8>?, len: Int) -> [RclGoalStatusRecord] {
    let stride = Int(CRCL_GOAL_STATUS_RECORD_SIZE)
    guard let buf, len >= stride else { return [] }
    let count = len / stride
    var out: [RclGoalStatusRecord] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        let rec = buf + i * stride
        let goalId = [UInt8](UnsafeBufferPointer(start: rec, count: 16))
        var sec: UInt32 = 0
        var nsec: UInt32 = 0
        for b in 0..<4 {
            sec |= UInt32(rec[16 + b]) << (8 * b)
            nsec |= UInt32(rec[20 + b]) << (8 * b)
        }
        out.append(
            RclGoalStatusRecord(
                goalId: goalId,
                stampSec: Int32(bitPattern: sec),
                stampNanosec: nsec,
                status: Int8(bitPattern: rec[24])
            ))
    }
    return out
}

/// C-callable bridge matching `crcl_action_client_callback_t`. Same Unmanaged
/// borrow contract as `rclResponseCallbackBridge`.
private func rclActionClientCallbackBridge(
    ctx: UnsafeMutableRawPointer?,
    role: Int32,
    sequenceNumber: Int64,
    buf: UnsafePointer<UInt8>?,
    len: Int
) {
    guard let ctx else { return }
    let clientContext = Unmanaged<RclActionClientContext>.fromOpaque(ctx).takeUnretainedValue()

    if role == CRCL_ACTION_CLIENT_STATUS {
        clientContext.callbacks.onStatus(rclParseStatusRecords(buf: buf, len: len))
        return
    }

    let payload: Data
    if let buf, len > 0 {
        payload = Data(bytes: buf, count: len)
    } else {
        payload = Data()
    }

    switch role {
    case CRCL_ACTION_CLIENT_GOAL_RESPONSE:
        clientContext.callbacks.onGoalResponse(sequenceNumber, payload)
    case CRCL_ACTION_CLIENT_CANCEL_RESPONSE:
        clientContext.callbacks.onCancelResponse(sequenceNumber, payload)
    case CRCL_ACTION_CLIENT_RESULT_RESPONSE:
        clientContext.callbacks.onResultResponse(sequenceNumber, payload)
    case CRCL_ACTION_CLIENT_FEEDBACK:
        clientContext.callbacks.onFeedback(payload)
    default:
        break
    }
}

/// Per-box lock serializes destroy vs. sends / availability checks on the
/// same action client pointer. Close contract mirrors `RclServiceClientBox`
/// exactly, including the leak-on-failed-destroy behavior.
private final class RclActionClientBox: RclActionClientHandle, @unchecked Sendable {
    private var ptr: OpaquePointer?
    private var contextBox: Unmanaged<RclActionClientContext>?
    private let lock = NSLock()

    init(_ ptr: OpaquePointer, contextBox: Unmanaged<RclActionClientContext>) {
        self.ptr = ptr
        self.contextBox = contextBox
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ptr != nil
    }

    func withPtr<R>(_ body: (OpaquePointer) -> R) -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = ptr else { return nil }
        return body(p)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let p = ptr {
            // crcl_action_client_destroy joins the wait thread before any
            // fini, so it blocks until any in-flight callback has returned.
            let rc = crcl_action_client_destroy(p)
            ptr = nil
            if rc < 0 {
                // Refused destroy — leak the retained handler context.
                contextBox = nil
                return
            }
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }
}

// MARK: - Client

/// Concrete implementation of ``RclClientProtocol`` wrapping the `CRclBridge` C FFI.
///
/// Thread-safety: the `ctx` pointer is read/written under `lock`.
/// `crcl_context_create` runs outside the lock (one-time init); the guard rejects
/// a second `createContext` call with `alreadyConnected`. `destroyContext`
/// snapshots and nils `ctx` under lock, then calls `crcl_context_destroy` outside.
/// Publisher and subscription create/destroy delegate thread-safety to the
/// per-`RclPublisherBox` / per-`RclSubscriptionBox` locks, mirroring the
/// `DDSClient` pattern. The retained `Unmanaged<RclSubscriptionContext>`
/// holding the user handler is released only *after* `crcl_subscription_destroy`
/// returns — the C bridge joins the wait thread before any fini, so a racing
/// callback can never dereference a freed closure context.
package final class RclClient: RclClientProtocol, @unchecked Sendable {
    private var ctx: OpaquePointer?
    private let lock = NSLock()
    /// Serializes every CYCLONEDDS_URI read/write across all RclClient instances
    /// in the process. CYCLONEDDS_URI is a single process-global slot and
    /// setenv/getenv are not mutually thread-safe, so the save+export and the
    /// read+restore must each run as one critical section under a SHARED lock —
    /// the per-instance `lock` cannot guard a process-global. (Concurrent
    /// contexts still share that one env slot; rmw_cyclonedds reads it once at
    /// first-participant creation, so this serializes the mutations rather than
    /// giving each context an independent value.)
    private static let envLock = NSLock()
    /// CYCLONEDDS_URI as it was BEFORE the first live holder applied one.
    /// Static + refcounted exactly like RMW_IMPLEMENTATION below: overlapping
    /// contexts — possibly on different RclClient instances — must never
    /// restore each other to a stale intermediate XML on a non-LIFO teardown.
    /// Outer optional = "captured"; inner = "was previously set". Guarded by
    /// `envLock`.
    private static var cyclonedDDSURISaved: String??
    /// Number of live contexts currently holding the CYCLONEDDS_URI slot.
    /// Restore to `cyclonedDDSURISaved` fires only when this returns to 0.
    /// Guarded by `envLock`.
    private static var cyclonedDDSURIRefCount = 0
    /// Whether THIS instance applied the discovery env and has not yet
    /// restored it — keeps restore idempotent per instance. Guarded by
    /// `envLock`.
    private var cyclonedDDSURIHeld = false
    #if os(Linux)
        /// Serializes RMW_IMPLEMENTATION reads/writes (process-global env slot).
        private static let rmwEnvLock = NSLock()
        /// RMW_IMPLEMENTATION as it was BEFORE the first live context applied one.
        /// Process-global (the env slot is), captured once on the outermost apply
        /// and restored once on the outermost teardown, so overlapping contexts —
        /// possibly on different RclClient instances — never restore each other to
        /// a stale intermediate value. Outer optional = "captured"; inner = "was
        /// previously set". Guarded by `rmwEnvLock`.
        private static var rmwEnvSaved: String??
        /// Number of live contexts currently holding the RMW_IMPLEMENTATION slot.
        /// Restore to `rmwEnvSaved` fires only when this returns to 0. Guarded by
        /// `rmwEnvLock`.
        private static var rmwEnvRefCount = 0
        /// Whether THIS instance's context applied the rmw env and has not yet
        /// restored it — makes restore idempotent per instance and keeps a
        /// teardown that never applied (or already restored) from decrementing
        /// another context's ref. Guarded by `rmwEnvLock`.
        private var rmwEnvHeld = false
    #endif
    /// Serializes ZENOH_SESSION_CONFIG_URI / ZENOH_ROUTER_CHECK_ATTEMPTS reads &
    /// writes across all RclClient instances (process-global env slots; same
    /// rationale as `envLock`).
    private static let zenohEnvLock = NSLock()
    /// Zenoh env as it was BEFORE the first live holder applied one (static +
    /// refcounted, same contract as CYCLONEDDS_URI above). Guarded by
    /// `zenohEnvLock`.
    private static var zenohSessionConfigURISaved: String??
    private static var zenohRouterCheckAttemptsSaved: String??
    /// Number of live contexts currently holding the Zenoh env slots.
    /// Guarded by `zenohEnvLock`.
    private static var zenohEnvRefCount = 0
    /// Temp files backing ZENOH_SESSION_CONFIG_URI across ALL live holders.
    /// Deleted only when the last hold drops: even a holder deleting its own
    /// file early would leave the still-exported env pointing at a dead path
    /// for any locator-less context created during the overlap window.
    /// Guarded by `zenohEnvLock`.
    private static var zenohLiveConfigFileURLs: [URL] = []
    /// Whether THIS instance applied the Zenoh env and has not yet restored
    /// it. Guarded by `zenohEnvLock`.
    private var zenohEnvHeld = false
    #if SWIFT_ROS2_RCL_RMW_ZENOH
        /// Saved AMENT_PREFIX_PATH to restore on destroyContext. Outer optional =
        /// "we saved"; inner = "was previously set". Guarded by `zenohEnvLock`.
        private var priorAmentPrefixPath: String??
        /// Synthesized minimal ament prefix directory backing AMENT_PREFIX_PATH;
        /// removed on restore. Guarded by `zenohEnvLock`.
        private var amentPrefixDirURL: URL?
    #endif
    /// Route-(b) sibling-participant session (`bridge_dds_session_t*`), created
    /// lazily on the first non-bundled publisher and matched to the rcl
    /// context's discovery. nil until then.
    private var rawSession: OpaquePointer?
    /// Discovery inputs captured at createContext so the route-(b) raw session
    /// discovers identically to the rcl context.
    private var ctxDomainId: Int32 = 0
    private var ctxUnicastPeerAddresses: [String] = []
    private var ctxNetworkInterface: String?
    /// Whether the most recent createContext asked for a `.zenoh` transport —
    /// on runtime-rmw platforms (Linux, MZ5) that selects rmw_zenoh_cpp, so the
    /// route-(b) CycloneDDS fallback must be gated off exactly as in the baked
    /// zenoh-rmw variant. Captured with the other context inputs; overwritten
    /// by the next createContext.
    private var ctxTransportIsZenoh = false

    package init() {}

    package var isAvailable: Bool { true }

    /// Build the CycloneDDS domain-config XML via the SHARED CDDSBridge builder
    /// (byte-identical to the wire DDS path → Axis-3 parity). Pure: no env, no
    /// DDS runtime. Returns nil on OOM. `package` so SwiftROS2RCLTests can assert
    /// the XML shape without starting rmw.
    package func makeDiscoveryURIXML(
        domainId: Int32, unicastPeerAddresses: [String], networkInterface: String?
    ) -> String? {
        var cConfig = bridge_discovery_config_t()
        cConfig.mode =
            unicastPeerAddresses.isEmpty ? BRIDGE_DISCOVERY_MULTICAST : BRIDGE_DISCOVERY_UNICAST
        var peerCStrings: [UnsafeMutablePointer<CChar>?] = unicastPeerAddresses.map { strdup($0) }
        peerCStrings.append(nil)
        let peersPtr = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(
            capacity: peerCStrings.count)
        defer {
            for s in peerCStrings where s != nil { free(s) }
            peersPtr.deallocate()
        }
        for (i, s) in peerCStrings.enumerated() { peersPtr[i] = s.map { UnsafePointer($0) } }
        if !unicastPeerAddresses.isEmpty {
            cConfig.unicast_peers = peersPtr
            cConfig.peer_count = Int32(unicastPeerAddresses.count)
        }
        var interfaceCString: UnsafeMutablePointer<CChar>?
        if let networkInterface {
            interfaceCString = strdup(networkInterface)
            cConfig.network_interface = UnsafePointer(interfaceCString)
        }
        defer { if let s = interfaceCString { free(s) } }
        guard let xmlPtr = dds_bridge_build_domain_config_xml(domainId, &cConfig) else { return nil }
        defer { dds_bridge_free_string(xmlPtr) }
        return String(cString: xmlPtr)
    }

    /// Build a minimal Zenoh **client** session config (json5) that connects to
    /// the given router locator (`tcp/<host>:<port>`), with multicast scouting
    /// disabled (we connect to a known router). rmw_zenoh_cpp reads this file via
    /// ZENOH_SESSION_CONFIG_URI at session creation. Pure: no env, no rmw.
    /// `package` so SwiftROS2RCLTests can assert the shape without a router.
    package func makeZenohSessionConfigJSON5(locator: String) -> String {
        // ZENOH_SESSION_CONFIG_URI REPLACES rmw_zenoh's DEFAULT_RMW_ZENOH_SESSION
        // _CONFIG.json5 wholesale — it is not merged — so any default this minimal
        // config omits reverts to the zenoh-c library default, not rmw_zenoh's.
        // `timestamping` is the one that bites: rmw_zenoh_cpp creates every
        // publisher as an AdvancedPublisher with Sequencing::Timestamp (needed for
        // the PublicationCache behind transient_local durability), and zenoh-c
        // refuses to build such a publisher unless timestamping is enabled — the
        // library default for a client is disabled, so a config without it aborts
        // the first publisher with "the 'timestamping' setting must be enabled in
        // the Zenoh configuration." Mirror the default's block verbatim (see
        // RmwZenohDefaultConfig, DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5).
        """
        {
          mode: "client",
          connect: {
            endpoints: ["\(locator)"],
          },
          scouting: {
            multicast: {
              enabled: false,
            },
          },
          timestamping: {
            enabled: { router: true, peer: true, client: true },
            drop_future_timestamp: false,
          },
        }
        """
    }

    /// True if `locator` is safe to embed verbatim in the json5 session-config
    /// string literal. A `"` or `\` (or a control char / newline) would close or
    /// corrupt the literal; a legitimate zenoh endpoint (`proto/host:port[#meta]`)
    /// never contains these. Reject such a locator with a clear error rather than
    /// escape it into a syntactically-valid-but-wrong endpoint the router would
    /// reject later, far from the cause. `package` so tests can assert the rule.
    package static func isEmbeddableZenohLocator(_ locator: String) -> Bool {
        !locator.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 }
    }

    /// Export the discovery XML as CYCLONEDDS_URI (saving the prior value) when
    /// discovery is non-default. Returns true if it set the env. rmw_cyclonedds
    /// reads CYCLONEDDS_URI once, at the first participant; pair with
    /// restoreDiscoveryEnv() on teardown or on a failed createContext.
    package func applyDiscoveryEnv(
        domainId: Int32, unicastPeerAddresses: [String], networkInterface: String?
    ) -> Bool {
        guard !unicastPeerAddresses.isEmpty || networkInterface != nil,
            let xml = makeDiscoveryURIXML(
                domainId: domainId, unicastPeerAddresses: unicastPeerAddresses,
                networkInterface: networkInterface)
        else { return false }
        // Save + export under the shared lock as one critical section: getenv and
        // setenv must not interleave with another instance's, or the saved value
        // and the live env desynchronize. Only the FIRST live holder captures
        // the pre-apply value; later holders just bump the ref count (the slot
        // itself stays last-writer-wins, as before).
        Self.envLock.lock()
        defer { Self.envLock.unlock() }
        if Self.cyclonedDDSURIRefCount == 0 {
            saveEnvSlotLocked(&Self.cyclonedDDSURISaved, "CYCLONEDDS_URI")
        }
        Self.cyclonedDDSURIRefCount += 1
        cyclonedDDSURIHeld = true
        setenv("CYCLONEDDS_URI", xml, 1)
        return true
    }

    /// Restore one saved env slot to its pre-apply value (unset it if it was
    /// previously unset), then clear the slot so a later call is a no-op. The
    /// `Optional(...)` wrap in the apply path distinguishes "saved, was unset"
    /// (`.some(.none)` → unset) from "never saved" (`.none` → no-op). Caller
    /// holds the relevant env lock.
    private func restoreEnvSlotLocked(_ saved: inout String??, _ name: String) {
        guard let prior = saved else { return }
        saved = nil
        if let p = prior { setenv(name, p, 1) } else { unsetenv(name) }
    }

    /// Save the current value of an env variable into its slot before the
    /// caller overwrites it — the counterpart of ``restoreEnvSlotLocked``.
    /// Wraps in `Optional(...)` so a previously-UNSET env becomes
    /// `.some(.none)` ("saved, was unset") rather than collapsing to `.none`
    /// ("never saved"); the restore side relies on that distinction to unset
    /// vs. no-op. Caller holds the relevant env lock.
    private func saveEnvSlotLocked(_ slot: inout String??, _ name: String) {
        slot = Optional(getenv(name).map { String(cString: $0) })
    }

    /// Drop this instance's hold on CYCLONEDDS_URI; the slot is restored to
    /// its pre-FIRST-apply value only when the last live holder drops, so a
    /// non-LIFO teardown never restores a stale intermediate XML. Idempotent
    /// per instance: a no-op when this instance holds nothing.
    package func restoreDiscoveryEnv() {
        // Read + restore under the shared lock as one critical section (see
        // applyDiscoveryEnv): the saved slot and the live env move together.
        Self.envLock.lock()
        defer { Self.envLock.unlock() }
        guard cyclonedDDSURIHeld else { return }
        cyclonedDDSURIHeld = false
        Self.cyclonedDDSURIRefCount -= 1
        if Self.cyclonedDDSURIRefCount == 0 {
            restoreEnvSlotLocked(&Self.cyclonedDDSURISaved, "CYCLONEDDS_URI")
        }
    }

    /// Write the Zenoh session config to a unique temp file and export
    /// ZENOH_SESSION_CONFIG_URI (+ ZENOH_ROUTER_CHECK_ATTEMPTS), saving the prior
    /// values. rmw_zenoh_cpp reads these once at session creation; pair with
    /// restoreZenohSessionEnv() on teardown or a failed createContext. Returns
    /// false if the temp file could not be written.
    package func applyZenohSessionEnv(locator: String) -> Bool {
        // Precondition: must not be called again before restoreZenohSessionEnv().
        // A second apply would orphan the first temp file and overwrite the saved
        // priors (same single-apply-per-context contract as applyDiscoveryEnv).
        let json5 = makeZenohSessionConfigJSON5(locator: locator)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-ros2-zenoh-\(UUID().uuidString).json5")
        guard (try? json5.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        Self.zenohEnvLock.lock()
        defer { Self.zenohEnvLock.unlock() }
        if Self.zenohEnvRefCount == 0 {
            saveEnvSlotLocked(&Self.zenohSessionConfigURISaved, "ZENOH_SESSION_CONFIG_URI")
            saveEnvSlotLocked(&Self.zenohRouterCheckAttemptsSaved, "ZENOH_ROUTER_CHECK_ATTEMPTS")
        }
        Self.zenohEnvRefCount += 1
        zenohEnvHeld = true
        Self.zenohLiveConfigFileURLs.append(url)
        setenv("ZENOH_SESSION_CONFIG_URI", url.path, 1)
        // Check for the router once, then continue: a mobile publisher must not
        // block context creation when the remote router is briefly unreachable.
        setenv("ZENOH_ROUTER_CHECK_ATTEMPTS", "1", 1)
        return true
    }

    /// Drop this instance's hold on the Zenoh env slots; they are restored to
    /// their pre-FIRST-apply values — and every held temp config file deleted
    /// — only when the last live holder drops, so a non-LIFO teardown never
    /// repoints the slot at a stale value or a deleted file. In the zenoh-rmw
    /// variant this also restores AMENT_PREFIX_PATH and deletes the
    /// synthesized ament prefix (per-instance: the prefix is re-synthesized
    /// and re-validated on every apply, so no refcount is needed there).
    /// Idempotent per instance: a no-op when this instance holds nothing.
    package func restoreZenohSessionEnv() {
        Self.zenohEnvLock.lock()
        defer { Self.zenohEnvLock.unlock() }
        if zenohEnvHeld {
            zenohEnvHeld = false
            Self.zenohEnvRefCount -= 1
            if Self.zenohEnvRefCount == 0 {
                restoreEnvSlotLocked(&Self.zenohSessionConfigURISaved, "ZENOH_SESSION_CONFIG_URI")
                restoreEnvSlotLocked(
                    &Self.zenohRouterCheckAttemptsSaved, "ZENOH_ROUTER_CHECK_ATTEMPTS")
                for url in Self.zenohLiveConfigFileURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                Self.zenohLiveConfigFileURLs.removeAll()
            }
        }
        #if SWIFT_ROS2_RCL_RMW_ZENOH
            restoreEnvSlotLocked(&priorAmentPrefixPath, "AMENT_PREFIX_PATH")
            if let dir = amentPrefixDirURL {
                try? FileManager.default.removeItem(at: dir)
                amentPrefixDirURL = nil
            }
        #endif
    }

    #if os(Linux)
        /// Linux selects the rmw at runtime (process-global RMW_IMPLEMENTATION).
        /// `.zenoh` ⇒ rmw_zenoh_cpp; `.dds`/`.rcl` ⇒ rmw_cyclonedds_cpp. The FIRST
        /// live context captures the pre-existing value process-globally; nested /
        /// overlapping contexts just bump the ref count. Pair each apply with
        /// exactly one restoreRmwImplementationEnv() on teardown or a failed
        /// create. Setting a process env slot cannot fail, so this always applies.
        package func applyRmwImplementationEnv(zenoh: Bool) {
            Self.rmwEnvLock.lock()
            defer { Self.rmwEnvLock.unlock() }
            if Self.rmwEnvRefCount == 0 {
                Self.rmwEnvSaved = Optional(
                    getenv("RMW_IMPLEMENTATION").map { String(cString: $0) })
            }
            Self.rmwEnvRefCount += 1
            rmwEnvHeld = true
            setenv("RMW_IMPLEMENTATION", zenoh ? "rmw_zenoh_cpp" : "rmw_cyclonedds_cpp", 1)
        }

        /// Release this context's hold on RMW_IMPLEMENTATION; when the last hold
        /// drops, restore the value captured before the first apply (unset what
        /// was unset). Idempotent per instance: a no-op when this instance holds
        /// no ref (never applied, or already restored).
        package func restoreRmwImplementationEnv() {
            Self.rmwEnvLock.lock()
            defer { Self.rmwEnvLock.unlock() }
            guard rmwEnvHeld else { return }
            rmwEnvHeld = false
            Self.rmwEnvRefCount -= 1
            guard Self.rmwEnvRefCount == 0, let saved = Self.rmwEnvSaved else { return }
            Self.rmwEnvSaved = nil
            if let s = saved { setenv("RMW_IMPLEMENTATION", s, 1) } else { unsetenv("RMW_IMPLEMENTATION") }
        }
    #endif

    #if SWIFT_ROS2_RCL_RMW_ZENOH
        /// True when one of the colon-separated ament prefixes registers
        /// `package` in its resource index. `package` so tests can assert it.
        package static func amentPrefixPath(_ path: String, registers package: String) -> Bool {
            path.split(separator: ":").contains { prefix in
                FileManager.default.fileExists(
                    atPath: "\(prefix)/share/ament_index/resource_index/packages/\(package)")
            }
        }

        /// True when ament_index (and therefore rmw_init) can resolve
        /// DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5 through one of the prefixes.
        package static func amentPrefixPathContainsRmwZenoh(_ path: String) -> Bool {
            amentPrefixPath(path, registers: "rmw_zenoh_cpp")
        }

        /// Splits an inherited AMENT_PREFIX_PATH into the prefixes this process
        /// may use and the ones that declare rosidl_buffer_backend plugins.
        /// rmw_zenoh_cpp >= 0.10 builds a pluginlib ClassLoader for that
        /// package at every init and dlopens each declared plugin — host
        /// .dylibs from a sourced ROS install, which fail or load foreign code
        /// into this statically linked stack. `package` for tests.
        package static func partitionInheritedAmentPrefixPath(_ path: String)
            -> (kept: [String], dropped: [String])
        {
            var kept: [String] = []
            var dropped: [String] = []
            for prefix in path.split(separator: ":").map(String.init) where !prefix.isEmpty {
                let pluginIndex =
                    "\(prefix)/share/ament_index/resource_index/rosidl_buffer_backend__pluginlib__plugin"
                if FileManager.default.fileExists(atPath: pluginIndex) {
                    dropped.append(prefix)
                } else {
                    kept.append(prefix)
                }
            }
            return (kept, dropped)
        }

        /// rmw_zenoh_cpp hard-requires AMENT_PREFIX_PATH at rmw_init to resolve
        /// its default session config via ament_index (at the pinned
        /// rmw_zenoh_cpp 0.10.7: `get_z_config` calls ament_index_cpp's
        /// `get_package_share_path`, which throws when the variable is unset or
        /// empty), and since 0.10 it also looks up the `rosidl_buffer_backend`
        /// package (an ERROR on every init when it is missing). A consumer app
        /// cannot be expected to export either, so this synthesizes a minimal
        /// prefix in a temp directory and exports it: always the
        /// `rosidl_buffer_backend` marker (declares no plugins, so nothing is
        /// dlopened), plus the `rmw_zenoh_cpp` marker and the two default json5
        /// configs when no inherited prefix registers rmw_zenoh_cpp. A complete
        /// inherited path is left untouched; prefixes that declare
        /// buffer-backend plugins are dropped for this process. Same
        /// single-apply-per-context contract as `applyZenohSessionEnv`; pair
        /// with `restoreZenohSessionEnv()` on teardown or a failed
        /// createContext. `package` so SwiftROS2RCLTests can exercise the
        /// synthesis without starting rmw.
        package func applyAmentPrefixEnv() throws {
            Self.zenohEnvLock.lock()
            defer { Self.zenohEnvLock.unlock() }
            let existing = getenv("AMENT_PREFIX_PATH").map { String(cString: $0) } ?? ""
            let (kept, dropped) = Self.partitionInheritedAmentPrefixPath(existing)
            let keptPath = kept.joined(separator: ":")
            let needsRmwZenoh = !Self.amentPrefixPathContainsRmwZenoh(keptPath)
            let needsBufferBackend = !Self.amentPrefixPath(keptPath, registers: "rosidl_buffer_backend")
            if dropped.isEmpty && !needsRmwZenoh && !needsBufferBackend {
                return  // complete user-provided prefix — leave it untouched
            }
            if !dropped.isEmpty {
                fputs(
                    "swift-ros2: dropping AMENT_PREFIX_PATH entries that declare rosidl_buffer_backend plugins (not loadable into this process): \(dropped.joined(separator: ", "))\n",
                    stderr)
            }
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("swift-ros2-ament-\(UUID().uuidString)", isDirectory: true)
            let markerDir = root.appendingPathComponent(
                "share/ament_index/resource_index/packages", isDirectory: true)
            let configDir = root.appendingPathComponent(
                "share/rmw_zenoh_cpp/config", isDirectory: true)
            do {
                try fm.createDirectory(at: markerDir, withIntermediateDirectories: true)
                // Empty marker files — their presence is what ament_index resolves.
                try Data().write(to: markerDir.appendingPathComponent("rosidl_buffer_backend"))
                if needsRmwZenoh {
                    try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
                    try Data().write(to: markerDir.appendingPathComponent("rmw_zenoh_cpp"))
                    try RmwZenohDefaultConfig.sessionConfigJSON5.write(
                        to: configDir.appendingPathComponent("DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5"),
                        atomically: true, encoding: .utf8)
                    try RmwZenohDefaultConfig.routerConfigJSON5.write(
                        to: configDir.appendingPathComponent("DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5"),
                        atomically: true, encoding: .utf8)
                }
            } catch {
                try? fm.removeItem(at: root)
                throw TransportError.connectionFailed(
                    "failed to synthesize the rmw_zenoh_cpp ament prefix at \(root.path): \(error)")
            }
            amentPrefixDirURL = root
            saveEnvSlotLocked(&priorAmentPrefixPath, "AMENT_PREFIX_PATH")
            // A synthesized rmw_zenoh config goes first; a marker-only prefix
            // goes last, so a user's own rmw_zenoh config keeps priority.
            let entries = needsRmwZenoh ? [root.path] + kept : kept + [root.path]
            setenv("AMENT_PREFIX_PATH", entries.joined(separator: ":"), 1)
        }
    #endif

    package func createContext(
        domainId: Int32, transportType: TransportType, unicastPeerAddresses: [String],
        networkInterface: String?, zenohRouterLocator: String?
    ) throws {
        lock.lock()
        guard ctx == nil else {
            lock.unlock()
            throw TransportError.alreadyConnected
        }
        // Capture the discovery inputs so a later route-(b) raw session matches
        // the rcl context's domain + peers + interface — and the transport
        // intent, which gates route-(b) off entirely for zenoh-backed contexts.
        ctxDomainId = domainId
        ctxUnicastPeerAddresses = unicastPeerAddresses
        ctxNetworkInterface = networkInterface
        ctxTransportIsZenoh = transportType == .zenoh
        lock.unlock()
        #if os(Linux)
            // Pick the process rmw from the transport TYPE (authoritative — not
            // the locator, which is nil for a locator-less multicast/P2P zenoh
            // session and would then mis-select rmw_cyclonedds_cpp). Restored on
            // teardown or any failed-create path below.
            applyRmwImplementationEnv(zenoh: transportType == .zenoh)
        #endif
        // DDS variant: export CYCLONEDDS_URI for non-default discovery.
        // Zenoh variant: export ZENOH_SESSION_CONFIG_URI for the router locator.
        // The two are mutually exclusive by build variant; rmw reads its env once
        // at first participant. Restore on teardown OR a failed create.
        let appliedDiscoveryEnv = applyDiscoveryEnv(
            domainId: domainId, unicastPeerAddresses: unicastPeerAddresses,
            networkInterface: networkInterface)
        // A configured locator MUST be honored — unlike DDS, where the absence of
        // an exported URI means "use default discovery", an unexported Zenoh
        // session config silently drops the publisher onto default (router-less,
        // multicast) settings. So a present-but-unappliable locator fails loudly
        // here instead of producing a connection that never reaches the router.
        if let locator = zenohRouterLocator {
            guard Self.isEmbeddableZenohLocator(locator) else {
                if appliedDiscoveryEnv { restoreDiscoveryEnv() }
                #if os(Linux)
                    restoreRmwImplementationEnv()
                #endif
                throw TransportError.invalidConfiguration(
                    "Zenoh router locator cannot be embedded in the session config "
                        + "(contains a quote, backslash, or control character): \(locator)")
            }
            guard applyZenohSessionEnv(locator: locator) else {
                if appliedDiscoveryEnv { restoreDiscoveryEnv() }
                #if os(Linux)
                    restoreRmwImplementationEnv()
                #endif
                throw TransportError.connectionFailed(
                    "failed to write the Zenoh session config for locator \(locator)")
            }
        }
        #if SWIFT_ROS2_RCL_RMW_ZENOH
            // Unconditional for the zenoh variant (locator or not): rmw_init
            // fails outright without a resolvable rmw_zenoh_cpp ament resource,
            // so context creation must be self-sufficient.
            do {
                try applyAmentPrefixEnv()
            } catch {
                if appliedDiscoveryEnv { restoreDiscoveryEnv() }
                #if os(Linux)
                    restoreRmwImplementationEnv()
                #endif
                restoreZenohSessionEnv()
                throw error
            }
        #endif
        guard let c = crcl_context_create(Int(domainId)) else {
            if appliedDiscoveryEnv { restoreDiscoveryEnv() }
            #if os(Linux)
                restoreRmwImplementationEnv()
            #endif
            // Idempotent — restores only the slots this context applied (the
            // session-config env when a locator was given; the AMENT prefix in
            // the zenoh variant) and no-ops on the rest.
            restoreZenohSessionEnv()
            throw TransportError.connectionFailed(lastError())
        }
        lock.lock()
        ctx = c
        lock.unlock()
    }

    package func destroyContext() {
        lock.lock()
        let c = ctx
        ctx = nil
        let rs = rawSession
        rawSession = nil
        lock.unlock()
        if let rs { dds_bridge_destroy_session(rs) }
        if let c { crcl_context_destroy(c) }
        restoreDiscoveryEnv()
        restoreZenohSessionEnv()
        #if os(Linux)
            restoreRmwImplementationEnv()
        #endif
    }

    package func createNode(name: String, namespace: String) throws -> any RclNodeHandle {
        lock.lock()
        let c = ctx
        lock.unlock()
        guard let c else { throw TransportError.notConnected }
        guard let n = crcl_node_create(c, name, namespace) else {
            throw TransportError.connectionFailed(lastError())
        }
        return RclNodeBox(n)
    }

    package func destroyNode(_ node: any RclNodeHandle) {
        guard let b = node as? RclNodeBox else { return }
        crcl_node_destroy(b.ptr)
    }

    package func graphPublishers(node: any RclNodeHandle) throws -> [RclGraphPublisherRecord] {
        guard let b = node as? RclNodeBox else {
            throw TransportError.invalidConfiguration("graphPublishers: not a node of this client")
        }
        let collector = RclGraphCollector()
        let ret = withExtendedLifetime(collector) {
            crcl_graph_snapshot(
                b.ptr, rclGraphPublisherCallbackBridge, Unmanaged.passUnretained(collector).toOpaque())
        }
        guard ret == 0 else {
            throw TransportError.sessionUnhealthy("rcl graph query failed: \(lastError())")
        }
        return collector.records
    }

    /// Fail-loud gate for zenoh-backed rcl graphs: on a marshal-registry miss
    /// the cyclonedds path falls back to route (b) — a raw-CDR writer /
    /// reader on a sibling **CycloneDDS** participant. Under rmw_zenoh the
    /// rcl graph speaks Zenoh through a router, so that sibling participant's
    /// DDS multicast domain has no counterpart: route-(b) traffic would go
    /// out (or be listened for) where nobody communicates — silent data
    /// loss, not degraded service. Throw instead. Applies both when the rmw
    /// is baked at compile time (SWIFT_ROS2_RCL_RMW_ZENOH) and when it is
    /// selected at runtime from the transport type (Linux, MZ5). Runs before
    /// the node handle is inspected, so SwiftROS2RCLTests can assert the gate
    /// without a live rmw context (`package` for exactly that).
    package static func requireBundledTypesupport(_ typeName: String) throws {
        guard crcl_marshal_resolve_typesupport(typeName) == nil else { return }
        throw TransportError.unsupportedFeature(
            "type \(typeName) has no bundled typesupport; the raw-CDR fallback is "
                + "CycloneDDS-only and unreachable via rmw_zenoh — bundle the type or "
                + "use the .dds transport")
    }

    /// Services and actions have no raw-CDR fallback on any rmw: a type missing
    /// from the srv / action registry cannot be served or called. Throw the same
    /// `unsupportedFeature` a topic of an unbundled type throws instead of the
    /// C bridge's creation failure. Runs before the node handle is inspected, so
    /// SwiftROS2RCLTests can assert it without a live rmw context.
    package static func requireBundledServiceTypesupport(_ srvTypeName: String) throws {
        guard crcl_srv_registry_lookup(srvTypeName) == nil else { return }
        throw TransportError.unsupportedFeature(
            "service type \(srvTypeName) has no bundled typesupport in the rcl backend "
                + "— use a bundled type or a wire transport")
    }

    /// The action counterpart of `requireBundledServiceTypesupport(_:)`.
    package static func requireBundledActionTypesupport(_ actionTypeName: String) throws {
        guard crcl_action_registry_lookup(actionTypeName) == nil else { return }
        throw TransportError.unsupportedFeature(
            "action type \(actionTypeName) has no bundled typesupport in the rcl backend "
                + "— use a bundled type or a wire transport")
    }

    /// Apply the fail-loud gate wherever the rcl graph speaks Zenoh: always in
    /// the baked zenoh-rmw variant (rmw fixed at compile time, gate must fire
    /// even before a context exists), and on a captured `.zenoh` transport
    /// intent where the rmw is selected at runtime (Linux, MZ5).
    private func requireBundledTypesupportIfZenohBacked(_ typeName: String) throws {
        #if SWIFT_ROS2_RCL_RMW_ZENOH
            try Self.requireBundledTypesupport(typeName)
        #else
            lock.lock()
            let zenohBacked = ctxTransportIsZenoh
            lock.unlock()
            if zenohBacked { try Self.requireBundledTypesupport(typeName) }
        #endif
    }

    package func createPublisher(
        node: any RclNodeHandle, typeName: String, typeHash: String?, topic: String,
        qos: TransportQoS
    ) throws -> any RclPublisherHandle {
        try requireBundledTypesupportIfZenohBacked(typeName)
        guard let b = node as? RclNodeBox else {
            throw TransportError.publisherCreationFailed("invalid node handle")
        }
        // Discriminate a registry miss (unbundled type → route (b)) from a real
        // rmw failure. crcl_publisher_create returns NULL for BOTH the
        // "unsupported type" registry gate AND genuine failures (invalid topic,
        // rcl_publisher_init error, OOM, bad node); it gates on the same
        // crcl_marshal_resolve_typesupport this checks. So: bundled type → a nil
        // is a real error, surface it; only an actual registry miss falls back.
        if crcl_marshal_resolve_typesupport(typeName) != nil {
            let q = makeCrclQoS(qos)
            guard let p = crcl_publisher_create(b.ptr, typeName, topic, q) else {
                throw TransportError.publisherCreationFailed(lastError())
            }
            return RclPublisherBox(p)
        }
        // Registry miss (unbundled type) → route-(b) raw-CDR writer below rmw.
        return try createRawWriterPublisher(
            typeName: typeName, typeHash: typeHash, topic: topic, qos: qos)
    }

    /// Lazily create (or reuse) the route-(b) sibling CycloneDDS participant,
    /// matching the rcl context's discovery (mirrors `makeDiscoveryURIXML`'s
    /// `bridge_discovery_config_t` marshalling, but calls
    /// `dds_bridge_create_session` instead of building XML).
    private func ensureRawSession() throws -> OpaquePointer {
        lock.lock()
        if let s = rawSession {
            lock.unlock()
            return s
        }
        let domain = ctxDomainId
        let peers = ctxUnicastPeerAddresses
        let iface = ctxNetworkInterface
        lock.unlock()

        var cConfig = bridge_discovery_config_t()
        cConfig.mode = peers.isEmpty ? BRIDGE_DISCOVERY_MULTICAST : BRIDGE_DISCOVERY_UNICAST
        var peerCStrings: [UnsafeMutablePointer<CChar>?] = peers.map { strdup($0) }
        peerCStrings.append(nil)
        let peersPtr = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(
            capacity: peerCStrings.count)
        defer {
            for s in peerCStrings where s != nil { free(s) }
            peersPtr.deallocate()
        }
        for (i, s) in peerCStrings.enumerated() { peersPtr[i] = s.map { UnsafePointer($0) } }
        if !peers.isEmpty {
            cConfig.unicast_peers = peersPtr
            cConfig.peer_count = Int32(peers.count)
        }
        var ifaceC: UnsafeMutablePointer<CChar>?
        if let iface {
            ifaceC = strdup(iface)
            cConfig.network_interface = UnsafePointer(ifaceC)
        }
        defer { if let s = ifaceC { free(s) } }

        guard let s = dds_bridge_create_session(domain, &cConfig) else {
            throw TransportError.publisherCreationFailed(
                "route-b raw session create failed: "
                    + "\(String(cString: dds_bridge_get_last_error()))")
        }
        lock.lock()
        // Re-check: another thread may have created the session while we were
        // unlocked building/creating ours. Keep the winner and destroy our
        // redundant one — overwriting rawSession here would leak a participant.
        if let existing = rawSession {
            lock.unlock()
            dds_bridge_destroy_session(s)
            return existing
        }
        rawSession = s
        lock.unlock()
        return s
    }

    /// Open a route-(b) raw-CDR writer for an unbundled type: a sibling
    /// participant on the context domain, keyed by the DDS topic + DDS type
    /// name (via SwiftROS2Wire) + USER_DATA typehash. rmw_cyclonedds does no
    /// XTypes checking, so a real ROS 2 subscriber matches on topic-name +
    /// DDS-type-name string.
    private func createRawWriterPublisher(
        typeName: String, typeHash: String?, topic: String, qos: TransportQoS
    ) throws -> any RclPublisherHandle {
        let session = try ensureRawSession()
        let ddsTopic = DDSWireCodec().ddsTopic(from: topic)  // "rt/<topic>"
        let ddsType = TypeNameConverter.toDDSTypeName(typeName)  // "<pkg>::msg::dds_::<Type>_"
        let userData: String? = typeHash.map { "typehash=\($0);" }
        // Honour the caller's QoS — a nil here makes the C bridge default to
        // best-effort/volatile (BRIDGE_QOS_SENSOR_DATA), silently dropping a
        // reliable/transient-local request the bundled (route-a) path would keep.
        var cQos = makeBridgeQoS(qos)
        let writer: OpaquePointer? = ddsTopic.withCString { t in
            ddsType.withCString { ty in
                if let ud = userData {
                    return ud.withCString {
                        dds_bridge_create_raw_writer(session, t, ty, &cQos, $0)
                    }
                }
                return dds_bridge_create_raw_writer(session, t, ty, &cQos, nil)
            }
        }
        guard let w = writer else {
            throw TransportError.publisherCreationFailed(
                "route-b raw writer create failed for \(typeName): "
                    + "\(String(cString: dds_bridge_get_last_error()))")
        }
        return RclRawPublisherBox(writer: w)
    }

    /// Open a route-(b) raw-CDR reader for an unbundled type: a sibling
    /// participant on the context domain, keyed by the DDS topic + DDS type name
    /// (via SwiftROS2Wire) + USER_DATA typehash. The mirror of
    /// `createRawWriterPublisher`; receipt is via the CycloneDDS listener
    /// callback (timestamp from the DDS source timestamp), outside rcl's wait-set
    /// — the same documented divergence as the writer.
    private func createRawReaderSubscription(
        typeName: String, typeHash: String?, topic: String, qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any RclSubscriptionHandle {
        let session = try ensureRawSession()
        let ddsTopic = DDSWireCodec().ddsTopic(from: topic)  // "rt/<topic>"
        let ddsType = TypeNameConverter.toDDSTypeName(typeName)  // "<pkg>::msg::dds_::<Type>_"
        let userData: String? = typeHash.map { "typehash=\($0);" }
        var cQos = makeBridgeQoS(qos)

        let contextBox = Unmanaged.passRetained(RclSubscriptionContext(handler: handler))
        let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())

        let reader: OpaquePointer? = ddsTopic.withCString { t in
            ddsType.withCString { ty in
                if let ud = userData {
                    return ud.withCString {
                        dds_bridge_create_raw_reader(
                            session, t, ty, &cQos, $0, rclRawReaderCallbackBridge, contextPtr)
                    }
                }
                return dds_bridge_create_raw_reader(
                    session, t, ty, &cQos, nil, rclRawReaderCallbackBridge, contextPtr)
            }
        }
        guard let r = reader else {
            contextBox.release()
            throw TransportError.subscriberCreationFailed(
                "route-b raw reader create failed for \(typeName): "
                    + "\(String(cString: dds_bridge_get_last_error()))")
        }
        // The samples of this process's transient-local writers that the reader got
        // while it was created; no lock is held here.
        dds_bridge_drain_reader(r)
        return RclRawSubscriptionBox(reader: r, contextBox: contextBox)
    }

    package func createSubscription(
        node: any RclNodeHandle,
        typeName: String,
        typeHash: String?,
        topic: String,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any RclSubscriptionHandle {
        try requireBundledTypesupportIfZenohBacked(typeName)
        guard let b = node as? RclNodeBox else {
            throw TransportError.subscriberCreationFailed("invalid node handle")
        }
        // Discriminate a registry miss (unbundled type → route (b)) from a real
        // failure: crcl_subscription_create gates on the same
        // crcl_marshal_resolve_typesupport. Bundled type → a nil is a real error.
        if crcl_marshal_resolve_typesupport(typeName) != nil {
            var q = makeCrclQoS(qos)
            let contextBox = Unmanaged.passRetained(RclSubscriptionContext(handler: handler))
            let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())
            guard
                let s = crcl_subscription_create(
                    b.ptr, typeName, topic, &q, rclTakeCallbackBridge, contextPtr)
            else {
                contextBox.release()
                throw TransportError.subscriberCreationFailed(lastError())
            }
            return RclSubscriptionBox(s, contextBox: contextBox)
        }
        // Registry miss (unbundled type) → route-(b) raw-CDR reader below rmw.
        return try createRawReaderSubscription(
            typeName: typeName, typeHash: typeHash, topic: topic, qos: qos, handler: handler)
    }

    package func destroySubscription(_ subscription: any RclSubscriptionHandle) {
        if let box = subscription as? RclSubscriptionBox {
            box.close()
        } else if let raw = subscription as? RclRawSubscriptionBox {
            raw.close()
        }
    }

    package func createServiceServer(
        node: any RclNodeHandle,
        srvTypeName: String,
        serviceName: String,
        qos: TransportQoS,
        onRequest: @escaping @Sendable (Data, [UInt8]) -> Void
    ) throws -> any RclServiceHandle {
        try Self.requireBundledServiceTypesupport(srvTypeName)
        guard let b = node as? RclNodeBox else {
            throw TransportError.subscriberCreationFailed("invalid node handle")
        }
        var q = makeCrclQoS(qos)

        let contextBox = Unmanaged.passRetained(RclServiceContext(onRequest: onRequest))
        let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())

        guard
            let s = crcl_service_create(
                b.ptr, srvTypeName, serviceName, &q, rclRequestCallbackBridge, contextPtr)
        else {
            contextBox.release()
            throw TransportError.subscriberCreationFailed(lastError())
        }
        return RclServiceBox(s, contextBox: contextBox)
    }

    package func sendResponse(_ service: any RclServiceHandle, requestId: [UInt8], data: Data) throws {
        guard let box = service as? RclServiceBox else {
            throw TransportError.publishFailed("invalid service handle")
        }
        guard requestId.count == Int(CRCL_REQUEST_ID_SIZE) else {
            throw TransportError.publishFailed(
                "request id must be \(CRCL_REQUEST_ID_SIZE) bytes, got \(requestId.count)")
        }
        let rc: Int32? = requestId.withUnsafeBufferPointer { idBuf -> Int32? in
            data.withUnsafeBytes { raw -> Int32? in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                return box.withPtr { p in
                    crcl_service_send_response(p, idBuf.baseAddress, base, data.count)
                }
            }
        }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func destroyServiceServer(_ service: any RclServiceHandle) {
        guard let box = service as? RclServiceBox else { return }
        box.close()
    }

    package func createServiceClient(
        node: any RclNodeHandle,
        srvTypeName: String,
        serviceName: String,
        qos: TransportQoS,
        onResponse: @escaping @Sendable (Int64, Data) -> Void
    ) throws -> any RclClientHandle {
        try Self.requireBundledServiceTypesupport(srvTypeName)
        guard let b = node as? RclNodeBox else {
            throw TransportError.subscriberCreationFailed("invalid node handle")
        }
        var q = makeCrclQoS(qos)

        let contextBox = Unmanaged.passRetained(RclServiceClientContext(onResponse: onResponse))
        let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())

        guard
            let c = crcl_client_create(
                b.ptr, srvTypeName, serviceName, &q, rclResponseCallbackBridge, contextPtr)
        else {
            contextBox.release()
            throw TransportError.subscriberCreationFailed(lastError())
        }
        return RclServiceClientBox(c, contextBox: contextBox)
    }

    package func sendRequest(_ client: any RclClientHandle, data: Data) throws -> Int64 {
        guard let box = client as? RclServiceClientBox else {
            throw TransportError.publishFailed("invalid service client handle")
        }
        var seq: Int64 = 0
        let rc: Int32? = data.withUnsafeBytes { raw -> Int32? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return box.withPtr { p in
                crcl_client_send_request(p, base, data.count, &seq)
            }
        }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
        return seq
    }

    package func serverAvailable(_ client: any RclClientHandle) -> Bool {
        guard let box = client as? RclServiceClientBox else { return false }
        return box.withPtr { crcl_client_server_available($0) == 1 } ?? false
    }

    package func publisherMatchedCount(_ publisher: any RclPublisherHandle) -> Int? {
        if let box = publisher as? RclPublisherBox {
            guard let n = box.withPtr({ crcl_publisher_subscription_count($0) }), n >= 0 else { return nil }
            return Int(n)
        }
        if let raw = publisher as? RclRawPublisherBox {
            return raw.matchedCount()
        }
        return nil
    }

    package func destroyServiceClient(_ client: any RclClientHandle) {
        guard let box = client as? RclServiceClientBox else { return }
        box.close()
    }

    // MARK: Actions (M8)

    package func createActionServer(
        node: any RclNodeHandle,
        actionTypeName: String,
        actionName: String,
        qos: TransportQoS,
        callbacks: RclActionServerCallbacks
    ) throws -> any RclActionServerHandle {
        try Self.requireBundledActionTypesupport(actionTypeName)
        guard let b = node as? RclNodeBox else {
            throw TransportError.subscriberCreationFailed("invalid node handle")
        }
        var q = makeCrclQoS(qos)

        let contextBox = Unmanaged.passRetained(RclActionServerContext(callbacks: callbacks))
        let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())

        guard
            let s = crcl_action_server_create(
                b.ptr, actionTypeName, actionName, &q, rclActionServerCallbackBridge, contextPtr)
        else {
            contextBox.release()
            throw TransportError.subscriberCreationFailed(lastError())
        }
        return RclActionServerBox(s, contextBox: contextBox)
    }

    /// Shared body for the three action-server response sends.
    private func sendActionResponse(
        _ server: any RclActionServerHandle, requestId: [UInt8], data: Data,
        send: (OpaquePointer, UnsafePointer<UInt8>?, UnsafePointer<UInt8>?, Int) -> Int32
    ) throws {
        guard let box = server as? RclActionServerBox else {
            throw TransportError.publishFailed("invalid action server handle")
        }
        guard requestId.count == Int(CRCL_REQUEST_ID_SIZE) else {
            throw TransportError.publishFailed(
                "request id must be \(CRCL_REQUEST_ID_SIZE) bytes, got \(requestId.count)")
        }
        let rc: Int32? = requestId.withUnsafeBufferPointer { idBuf -> Int32? in
            data.withUnsafeBytes { raw -> Int32? in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                return box.withPtr { p in
                    send(p, idBuf.baseAddress, base, data.count)
                }
            }
        }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func sendGoalResponse(
        _ server: any RclActionServerHandle, requestId: [UInt8], data: Data
    ) throws {
        try sendActionResponse(server, requestId: requestId, data: data) {
            crcl_action_server_send_goal_response($0, $1, $2, $3)
        }
    }

    package func sendCancelResponse(
        _ server: any RclActionServerHandle, requestId: [UInt8], data: Data
    ) throws {
        try sendActionResponse(server, requestId: requestId, data: data) {
            crcl_action_server_send_cancel_response($0, $1, $2, $3)
        }
    }

    package func sendResultResponse(
        _ server: any RclActionServerHandle, requestId: [UInt8], data: Data
    ) throws {
        try sendActionResponse(server, requestId: requestId, data: data) {
            crcl_action_server_send_result_response($0, $1, $2, $3)
        }
    }

    package func publishActionFeedback(_ server: any RclActionServerHandle, data: Data) throws {
        guard let box = server as? RclActionServerBox else {
            throw TransportError.publishFailed("invalid action server handle")
        }
        let rc: Int32? = data.withUnsafeBytes { raw -> Int32? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return box.withPtr { p in
                crcl_action_server_publish_feedback(p, base, data.count)
            }
        }
        guard let rc else { throw TransportError.publisherClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func publishActionStatus(_ server: any RclActionServerHandle) throws {
        guard let box = server as? RclActionServerBox else {
            throw TransportError.publishFailed("invalid action server handle")
        }
        let rc: Int32? = box.withPtr { crcl_action_server_publish_status($0) }
        guard let rc else { throw TransportError.publisherClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func acceptGoal(
        _ server: any RclActionServerHandle, goalId: [UInt8], stampSec: Int32,
        stampNanosec: UInt32
    ) throws {
        guard let box = server as? RclActionServerBox else {
            throw TransportError.publishFailed("invalid action server handle")
        }
        guard goalId.count == 16 else {
            throw TransportError.publishFailed("goal id must be 16 bytes, got \(goalId.count)")
        }
        let rc: Int32? = goalId.withUnsafeBufferPointer { idBuf -> Int32? in
            box.withPtr { p in
                crcl_action_server_accept_goal(p, idBuf.baseAddress, stampSec, stampNanosec)
            }
        }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func updateGoalState(
        _ server: any RclActionServerHandle, goalId: [UInt8], event: RclGoalEvent
    ) throws {
        guard let box = server as? RclActionServerBox else {
            throw TransportError.publishFailed("invalid action server handle")
        }
        guard goalId.count == 16 else {
            throw TransportError.publishFailed("goal id must be 16 bytes, got \(goalId.count)")
        }
        let rc: Int32? = goalId.withUnsafeBufferPointer { idBuf -> Int32? in
            box.withPtr { p in
                crcl_action_server_update_goal_state(p, idBuf.baseAddress, event.rawValue)
            }
        }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func notifyGoalDone(_ server: any RclActionServerHandle) throws {
        guard let box = server as? RclActionServerBox else {
            throw TransportError.publishFailed("invalid action server handle")
        }
        let rc: Int32? = box.withPtr { crcl_action_server_notify_goal_done($0) }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    package func destroyActionServer(_ server: any RclActionServerHandle) {
        guard let box = server as? RclActionServerBox else { return }
        box.close()
    }

    package func createActionClient(
        node: any RclNodeHandle,
        actionTypeName: String,
        actionName: String,
        qos: TransportQoS,
        callbacks: RclActionClientCallbacks
    ) throws -> any RclActionClientHandle {
        try Self.requireBundledActionTypesupport(actionTypeName)
        guard let b = node as? RclNodeBox else {
            throw TransportError.subscriberCreationFailed("invalid node handle")
        }
        var q = makeCrclQoS(qos)

        let contextBox = Unmanaged.passRetained(RclActionClientContext(callbacks: callbacks))
        let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())

        guard
            let c = crcl_action_client_create(
                b.ptr, actionTypeName, actionName, &q, rclActionClientCallbackBridge, contextPtr)
        else {
            contextBox.release()
            throw TransportError.subscriberCreationFailed(lastError())
        }
        return RclActionClientBox(c, contextBox: contextBox)
    }

    /// Shared body for the three action-client request sends.
    private func sendActionRequest(
        _ client: any RclActionClientHandle, data: Data,
        send: (OpaquePointer, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Int64>) -> Int32
    ) throws -> Int64 {
        guard let box = client as? RclActionClientBox else {
            throw TransportError.publishFailed("invalid action client handle")
        }
        var seq: Int64 = 0
        let rc: Int32? = data.withUnsafeBytes { raw -> Int32? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return box.withPtr { p in
                send(p, base, data.count, &seq)
            }
        }
        guard let rc else { throw TransportError.sessionClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
        return seq
    }

    package func sendGoalRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
        try sendActionRequest(client, data: data) {
            crcl_action_client_send_goal_request($0, $1, $2, $3)
        }
    }

    package func sendCancelRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
        try sendActionRequest(client, data: data) {
            crcl_action_client_send_cancel_request($0, $1, $2, $3)
        }
    }

    package func sendResultRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
        try sendActionRequest(client, data: data) {
            crcl_action_client_send_result_request($0, $1, $2, $3)
        }
    }

    package func actionServerAvailable(_ client: any RclActionClientHandle) -> Bool {
        guard let box = client as? RclActionClientBox else { return false }
        return box.withPtr { crcl_action_client_server_available($0) == 1 } ?? false
    }

    package func destroyActionClient(_ client: any RclActionClientHandle) {
        guard let box = client as? RclActionClientBox else { return }
        box.close()
    }

    package func publishSerialized(_ publisher: any RclPublisherHandle, data: Data) throws {
        // Route-(b) raw-CDR writer (unbundled type) — publish below rmw. Surface
        // a write failure the same way the typed path does, instead of reporting
        // success when nothing went on the wire.
        if let raw = publisher as? RclRawPublisherBox {
            guard let rc = raw.write(data) else { throw TransportError.publisherClosed }
            if rc != 0 {
                throw TransportError.publishFailed(String(cString: dds_bridge_get_last_error()))
            }
            return
        }
        guard let b = publisher as? RclPublisherBox else {
            throw TransportError.publishFailed("invalid publisher handle")
        }
        let rc: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return b.withPtr { p in
                crcl_publish_serialized(p, base, data.count)
            }
        }
        guard let rc else { throw TransportError.publisherClosed }
        if rc != 0 { throw TransportError.publishFailed(lastError()) }
    }

    private func makeCrclQoS(_ qos: TransportQoS) -> crcl_qos_t {
        var q = crcl_qos_t()
        q.reliability = qos.reliability == .reliable ? Int32(1) : Int32(0)
        q.durability = qos.durability == .transientLocal ? Int32(1) : Int32(0)
        switch qos.history {
        case .keepLast(let depth):
            q.history = Int32(0)
            q.depth = depth
        case .keepAll:
            q.history = Int32(1)
            q.depth = 0
        }
        return q
    }

    /// Map TransportQoS to the CDDSBridge config used by the route-(b) raw
    /// writer (mirrors the pure-Swift DDS backend's QoS marshalling), so an
    /// unbundled-type publisher honours the same reliability/durability/history
    /// knobs as a bundled one instead of falling back to sensor-data defaults.
    /// `package` so SwiftROS2RCLTests can assert the mapping without rmw.
    package func makeBridgeQoS(_ qos: TransportQoS) -> bridge_qos_config_t {
        var c = bridge_qos_config_t()
        c.reliability =
            qos.reliability == .reliable ? BRIDGE_RELIABILITY_RELIABLE : BRIDGE_RELIABILITY_BEST_EFFORT
        c.durability =
            qos.durability == .transientLocal ? BRIDGE_DURABILITY_TRANSIENT_LOCAL : BRIDGE_DURABILITY_VOLATILE
        switch qos.history {
        case .keepLast(let depth):
            c.history_kind = BRIDGE_HISTORY_KEEP_LAST
            c.history_depth = Int32(depth)
        case .keepAll:
            c.history_kind = BRIDGE_HISTORY_KEEP_ALL
            c.history_depth = 0
        }
        return c
    }

    private func lastError() -> String { String(cString: crcl_last_error()) }
}
