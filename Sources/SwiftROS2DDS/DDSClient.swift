// DDSClient.swift
// Default implementation of DDSClientProtocol using the CDDSBridge C FFI.

import CDDSBridge
import Foundation
import SwiftROS2Transport

// MARK: - Writer handle

/// Per-box lock serializes destroy vs. publish for the same writer so callers
/// can use writers from multiple threads without racing destroy/write on a
/// freed pointer. Different writers hold different locks, so parallel writes
/// across writers stay lock-free.
private final class DDSWriterHandleBox: DDSWriterHandle {
    private var writer: OpaquePointer?
    private let lock = NSLock()

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let w = writer else { return false }
        return dds_bridge_writer_is_active(w)
    }

    init(_ writer: OpaquePointer) {
        self.writer = writer
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let w = writer {
            dds_bridge_destroy_writer(w)
            writer = nil
        }
    }

    /// Invokes `body` with the live writer pointer while holding the per-box
    /// lock so concurrent `close()` cannot free it mid-call. Returns nil if
    /// the writer has already been closed.
    func withWriter<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let w = writer else { return nil }
        return body(w)
    }
}

// MARK: - Reader handle

/// Retained by `DDSReaderHandleBox.contextBox` while the reader is alive.
/// The `@unchecked Sendable` is justified: the class holds an immutable
/// `@Sendable` closure reference; the closure captures are the only
/// state shared across threads, and Swift's concurrency model already
/// requires those to be Sendable.
private final class DDSReaderContext: @unchecked Sendable {
    let handler: @Sendable (Data, UInt64) -> Void
    init(handler: @escaping @Sendable (Data, UInt64) -> Void) {
        self.handler = handler
    }
}

/// C-callable bridge matching `dds_bridge_data_callback_t`.
/// The `context` pointer is an `Unmanaged<DDSReaderContext>` opaque pointer
/// created via `passRetained` in `createRawReader`; here we only borrow it
/// (`takeUnretainedValue`) — retention is released in `DDSReaderHandleBox.close()`.
private func ddsReaderCallbackBridge(
    cdrData: UnsafePointer<UInt8>?,
    cdrLen: Int,
    timestampNs: UInt64,
    context: UnsafeMutableRawPointer?
) {
    guard let context = context else { return }
    let readerContext = Unmanaged<DDSReaderContext>.fromOpaque(context).takeUnretainedValue()

    let payload: Data
    if let cdrData = cdrData, cdrLen > 0 {
        payload = Data(bytes: cdrData, count: cdrLen)
    } else {
        payload = Data()
    }

    readerContext.handler(payload, timestampNs)
}

/// Per-box lock serializes destroy vs. isActive checks for the same reader.
/// Different readers hold different locks, so parallel reads stay lock-free.
private final class DDSReaderHandleBox: DDSReaderHandle {
    private var reader: OpaquePointer?
    private var contextBox: Unmanaged<DDSReaderContext>?
    private let lock = NSLock()

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let r = reader else { return false }
        return dds_bridge_reader_is_active(r)
    }

    init(_ reader: OpaquePointer, contextBox: Unmanaged<DDSReaderContext>) {
        self.reader = reader
        self.contextBox = contextBox
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let r = reader {
            // dds_bridge_destroy_reader blocks until any in-flight callback
            // returns. Only after it returns is it safe to release the retained
            // closure context, because no further callback invocations will
            // dereference it.
            dds_bridge_destroy_reader(r)
            reader = nil
        }
        if let box = contextBox {
            box.release()
            contextBox = nil
        }
    }

    /// Invokes `body` with the live reader pointer while holding the per-box
    /// lock so concurrent `close()` cannot free it mid-call. Returns nil if
    /// the reader has already been closed.
    func withReader<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let r = reader else { return nil }
        return body(r)
    }
}

// MARK: - Discovery snapshot

/// Collects one `dds_bridge_enumerate_publications` call's callbacks. Only touched
/// on the calling thread, during the call.
private final class DDSDiscoveryCollector {
    var publications: [DDSDiscoveredPublication] = []
    var participants: [[UInt8]] = []
}

private func ddsGUID(_ pointer: UnsafePointer<UInt8>?) -> [UInt8] {
    guard let pointer else { return [] }
    return Array(UnsafeBufferPointer(start: pointer, count: Int(DDS_BRIDGE_GUID_SIZE)))
}

/// C-callable bridge matching `dds_bridge_publication_callback_t`.
private func ddsPublicationCallbackBridge(
    info: UnsafePointer<bridge_publication_info_t>?, context: UnsafeMutableRawPointer?
) {
    guard let info = info?.pointee, let context, let topic = info.topic_name, let type = info.type_name else {
        return
    }
    let collector = Unmanaged<DDSDiscoveryCollector>.fromOpaque(context).takeUnretainedValue()
    let reliability: DDSDiscoveredPublication.Reliability
    switch info.reliability {
    case BRIDGE_DISCOVERED_RELIABILITY_RELIABLE: reliability = .reliable
    case BRIDGE_DISCOVERED_RELIABILITY_BEST_EFFORT: reliability = .bestEffort
    default: reliability = .unknown
    }
    let durability: DDSDiscoveredPublication.Durability
    switch info.durability {
    case BRIDGE_DISCOVERED_DURABILITY_VOLATILE: durability = .volatile
    case BRIDGE_DISCOVERED_DURABILITY_TRANSIENT_LOCAL: durability = .transientLocal
    case BRIDGE_DISCOVERED_DURABILITY_TRANSIENT: durability = .transient
    case BRIDGE_DISCOVERED_DURABILITY_PERSISTENT: durability = .persistent
    default: durability = .unknown
    }
    collector.publications.append(
        DDSDiscoveredPublication(
            endpointGUID: ddsGUID(info.endpoint_guid), participantGUID: ddsGUID(info.participant_guid),
            topicName: String(cString: topic), typeName: String(cString: type),
            reliability: reliability, durability: durability))
}

/// C-callable bridge matching `dds_bridge_participant_callback_t`.
private func ddsParticipantCallbackBridge(guid: UnsafePointer<UInt8>?, context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let collector = Unmanaged<DDSDiscoveryCollector>.fromOpaque(context).takeUnretainedValue()
    collector.participants.append(ddsGUID(guid))
}

// MARK: - DDSClient

/// Thread-safety: the client-level `NSLock` serializes `createSession` /
/// `destroySession` / `isConnected` / `getSessionId` / `createRawWriter` /
/// `createRawReader`. `writeRawCDR` and `destroyWriter` do not take the
/// client-level lock so parallel writes across different writers stay
/// unserialized, but each writer carries its own per-`DDSWriterHandleBox`
/// lock that serializes `writeRawCDR` against `destroyWriter` for the *same*
/// writer (preventing use-after-free on the underlying CycloneDDS writer
/// pointer). Callers must still ensure writers outlive the session.
/// Readers follow the same per-box lock discipline: each reader carries its
/// own `DDSReaderHandleBox` lock that serializes `close()` against
/// `isActive`, and the retained `Unmanaged<DDSReaderContext>` holding the
/// user handler is released only *after* `dds_bridge_destroy_reader`
/// returns — CycloneDDS contracts that call to block until any in-flight
/// listener callback has returned, so a racing callback thread can never
/// dereference a freed closure context.
package final class DDSClient: DDSClientProtocol {
    private var session: OpaquePointer?
    private let lock = NSLock()

    /// Initializes the client; call `open` / `createSession` to connect.
    package init() {}

    package var isAvailable: Bool {
        dds_bridge_is_available()
    }

    package func createSession(
        domainId: Int32,
        discoveryConfig: DDSBridgeDiscoveryConfig
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard session == nil else {
            throw DDSError.sessionCreationFailed("session already exists")
        }

        guard dds_bridge_is_available() else {
            throw DDSError.notAvailable
        }

        var cConfig = bridge_discovery_config_t()
        switch discoveryConfig.mode {
        case .multicast: cConfig.mode = BRIDGE_DISCOVERY_MULTICAST
        case .unicast: cConfig.mode = BRIDGE_DISCOVERY_UNICAST
        case .hybrid: cConfig.mode = BRIDGE_DISCOVERY_HYBRID
        }

        // Build peer C-string array
        var peerCStrings: [UnsafeMutablePointer<CChar>?] = discoveryConfig.unicastPeers.map { strdup($0) }
        peerCStrings.append(nil)  // NULL-terminator for C array

        let peersPtr = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: peerCStrings.count)
        defer {
            // Free peer strings + pointer array once dds_bridge_create_session returns
            for s in peerCStrings where s != nil {
                free(s)
            }
            peersPtr.deallocate()
        }
        for (i, s) in peerCStrings.enumerated() {
            peersPtr[i] = s.map { UnsafePointer($0) }
        }
        if !discoveryConfig.unicastPeers.isEmpty {
            cConfig.unicast_peers = peersPtr
            cConfig.peer_count = Int32(discoveryConfig.unicastPeers.count)
        }

        var interfaceCString: UnsafeMutablePointer<CChar>?
        if let ifaceName = discoveryConfig.networkInterface {
            interfaceCString = strdup(ifaceName)
            cConfig.network_interface = UnsafePointer(interfaceCString)
        }
        defer {
            if let s = interfaceCString { free(s) }
        }

        guard let newSession = dds_bridge_create_session(domainId, &cConfig) else {
            let msg = String(cString: dds_bridge_get_last_error())
            throw DDSError.sessionCreationFailed(msg)
        }
        session = newSession
    }

    package func destroySession() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let s = session else { return }
        dds_bridge_destroy_session(s)
        session = nil
    }

    package func isConnected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let s = session else { return false }
        return dds_bridge_session_is_connected(s)
    }

    package func getSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = session else { return nil }
        var buf = [CChar](repeating: 0, count: 33)
        guard dds_bridge_get_session_id(s, &buf, 33) == 0 else { return nil }
        return String(cString: buf)
    }

    package func createRawWriter(
        topicName: String,
        typeName: String,
        qos: DDSBridgeQoSConfig,
        userData: String?
    ) throws -> any DDSWriterHandle {
        lock.lock()
        defer { lock.unlock() }

        guard let s = session else {
            throw DDSError.notConnected
        }

        var cQos = bridge_qos_config_t()
        cQos.reliability = qos.reliability == .reliable ? BRIDGE_RELIABILITY_RELIABLE : BRIDGE_RELIABILITY_BEST_EFFORT
        cQos.durability =
            qos.durability == .transientLocal ? BRIDGE_DURABILITY_TRANSIENT_LOCAL : BRIDGE_DURABILITY_VOLATILE
        cQos.history_kind = qos.historyKind == .keepAll ? BRIDGE_HISTORY_KEEP_ALL : BRIDGE_HISTORY_KEEP_LAST
        cQos.history_depth = qos.historyDepth

        let writerOrNil: OpaquePointer? = topicName.withCString { topicCStr in
            typeName.withCString { typeCStr in
                if let userData = userData {
                    return userData.withCString { userDataCStr in
                        dds_bridge_create_raw_writer(s, topicCStr, typeCStr, &cQos, userDataCStr)
                    }
                } else {
                    return dds_bridge_create_raw_writer(s, topicCStr, typeCStr, &cQos, nil)
                }
            }
        }

        guard let writer = writerOrNil else {
            let msg = String(cString: dds_bridge_get_last_error())
            throw DDSError.writerCreationFailed(msg)
        }
        return DDSWriterHandleBox(writer)
    }

    package func writeRawCDR(
        writer: any DDSWriterHandle,
        data: Data,
        timestamp: UInt64
    ) throws {
        guard let box = writer as? DDSWriterHandleBox else {
            throw DDSError.writeFailed("foreign DDS writer handle")
        }
        let result: Int32? = data.withUnsafeBytes { buf -> Int32? in
            guard let ptr = buf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return box.withWriter { raw in
                dds_bridge_write_raw_cdr(raw, ptr, data.count, timestamp)
            }
        }
        guard let code = result else {
            throw DDSError.writeFailed("DDS writer handle has been closed")
        }
        if code != 0 {
            let msg = String(cString: dds_bridge_get_last_error())
            throw DDSError.writeFailed("dds_bridge_write_raw_cdr=\(code): \(msg)")
        }
    }

    package func destroyWriter(_ writer: any DDSWriterHandle) {
        guard let box = writer as? DDSWriterHandleBox else { return }
        box.close()
    }

    package func publicationMatchedCount(writer: any DDSWriterHandle) -> Int? {
        guard let box = writer as? DDSWriterHandleBox,
            let count = box.withWriter({ dds_bridge_writer_matched_count($0) }),
            count >= 0
        else { return nil }
        return Int(count)
    }

    package func isPublicationMatched(writer: any DDSWriterHandle) -> Bool {
        (publicationMatchedCount(writer: writer) ?? 0) > 0
    }

    package func isSubscriptionMatched(reader: any DDSReaderHandle) -> Bool {
        guard let box = reader as? DDSReaderHandleBox,
            let count = box.withReader({ dds_bridge_reader_matched_count($0) })
        else { return false }
        return count > 0
    }

    package func participantGUID() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = session else { return nil }
        return Self.readGUID { dds_bridge_get_participant_guid(s, $0) }
    }

    package func writerGUID(_ writer: any DDSWriterHandle) -> [UInt8]? {
        guard let box = writer as? DDSWriterHandleBox else { return nil }
        return box.withWriter { w in Self.readGUID { dds_bridge_writer_get_guid(w, $0) } } ?? nil
    }

    package func readerGUID(_ reader: any DDSReaderHandle) -> [UInt8]? {
        guard let box = reader as? DDSReaderHandleBox else { return nil }
        return box.withReader { r in Self.readGUID { dds_bridge_reader_get_guid(r, $0) } } ?? nil
    }

    /// Reads the builtin `DCPSPublication` and `DCPSParticipant` topics through the
    /// bridge. Holds the client lock, so it never races `destroySession`; the bridge
    /// calls back synchronously and the callbacks only append to the collector.
    package func discoverySnapshot() throws -> DDSDiscoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let s = session else { throw DDSError.notConnected }

        let collector = DDSDiscoveryCollector()
        let rc = withExtendedLifetime(collector) {
            dds_bridge_enumerate_publications(
                s, ddsPublicationCallbackBridge, ddsParticipantCallbackBridge,
                Unmanaged.passUnretained(collector).toOpaque())
        }
        guard rc == 0 else {
            throw DDSError.discoveryFailed(String(cString: dds_bridge_get_last_error()))
        }
        return DDSDiscoverySnapshot(publications: collector.publications, participantGUIDs: collector.participants)
    }

    /// Runs a bridge GUID query into a fresh `DDS_BRIDGE_GUID_SIZE`-byte buffer.
    private static func readGUID(_ query: (UnsafeMutablePointer<UInt8>) -> Int32) -> [UInt8]? {
        var guid = [UInt8](repeating: 0, count: Int(DDS_BRIDGE_GUID_SIZE))
        let rc = guid.withUnsafeMutableBufferPointer { buf in query(buf.baseAddress!) }
        return rc == 0 ? guid : nil
    }

    package func createRawReader(
        topicName: String,
        typeName: String,
        qos: DDSBridgeQoSConfig,
        userData: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any DDSReaderHandle {
        let (reader, contextBox) = try createRawReaderLocked(
            topicName: topicName, typeName: typeName, qos: qos, userData: userData, handler: handler)
        // Outside the client lock, so a handler that calls back into the client cannot
        // deadlock on it. Nothing else holds the handle yet, so it cannot be closed here.
        dds_bridge_drain_reader(reader)
        return DDSReaderHandleBox(reader, contextBox: contextBox)
    }

    private func createRawReaderLocked(
        topicName: String,
        typeName: String,
        qos: DDSBridgeQoSConfig,
        userData: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> (OpaquePointer, Unmanaged<DDSReaderContext>) {
        lock.lock()
        defer { lock.unlock() }

        guard let s = session else {
            throw DDSError.notConnected
        }

        var cQos = bridge_qos_config_t()
        cQos.reliability =
            qos.reliability == .reliable ? BRIDGE_RELIABILITY_RELIABLE : BRIDGE_RELIABILITY_BEST_EFFORT
        cQos.durability =
            qos.durability == .transientLocal ? BRIDGE_DURABILITY_TRANSIENT_LOCAL : BRIDGE_DURABILITY_VOLATILE
        cQos.history_kind =
            qos.historyKind == .keepAll ? BRIDGE_HISTORY_KEEP_ALL : BRIDGE_HISTORY_KEEP_LAST
        cQos.history_depth = qos.historyDepth

        let contextBox = Unmanaged.passRetained(DDSReaderContext(handler: handler))
        let contextPtr = UnsafeMutableRawPointer(contextBox.toOpaque())

        let readerOrNil: OpaquePointer? = topicName.withCString { topicCStr in
            typeName.withCString { typeCStr in
                if let userData = userData {
                    return userData.withCString { userDataCStr in
                        dds_bridge_create_raw_reader(
                            s, topicCStr, typeCStr, &cQos, userDataCStr,
                            ddsReaderCallbackBridge, contextPtr
                        )
                    }
                } else {
                    return dds_bridge_create_raw_reader(
                        s, topicCStr, typeCStr, &cQos, nil,
                        ddsReaderCallbackBridge, contextPtr
                    )
                }
            }
        }

        guard let reader = readerOrNil else {
            contextBox.release()
            let msg = String(cString: dds_bridge_get_last_error())
            throw DDSError.readerCreationFailed(msg)
        }

        return (reader, contextBox)
    }

    package func destroyReader(_ reader: any DDSReaderHandle) {
        guard let box = reader as? DDSReaderHandleBox else { return }
        box.close()
    }
}
