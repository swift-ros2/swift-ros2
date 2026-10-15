// DDSClientProtocol.swift
// Protocol abstraction for DDS (CycloneDDS) C-FFI bridge
//
// This protocol allows swift-ros2 to use DDS transport without
// directly depending on the C bridge. The consuming app (e.g., Conduit)
// provides a concrete implementation that calls the C functions.

import Foundation

// MARK: - Handle Protocols

/// Handle to a DDS writer; `DDSClientProtocol.destroyWriter` closes it
package protocol DDSWriterHandle: AnyObject {
    var isActive: Bool { get }
}

/// Handle to a DDS reader; `DDSClientProtocol.destroyReader` closes it
package protocol DDSReaderHandle: AnyObject {
    var isActive: Bool { get }
}

// MARK: - DDS Configuration Types

/// DDS discovery mode
package enum DDSBridgeDiscoveryMode: Int32, Sendable {
    case multicast = 0
    case unicast = 1
    case hybrid = 2
}

/// DDS discovery configuration
package struct DDSBridgeDiscoveryConfig: Sendable {
    package let mode: DDSBridgeDiscoveryMode
    package let unicastPeers: [String]
    package let networkInterface: String?

    package init(mode: DDSBridgeDiscoveryMode, unicastPeers: [String] = [], networkInterface: String? = nil) {
        self.mode = mode
        self.unicastPeers = unicastPeers
        self.networkInterface = networkInterface
    }
}

/// DDS QoS configuration for the bridge
package struct DDSBridgeQoSConfig: Sendable {
    package enum Reliability: Int32, Sendable {
        case bestEffort = 0
        case reliable = 1
    }

    package enum Durability: Int32, Sendable {
        case volatile = 0
        case transientLocal = 1
    }

    package enum HistoryKind: Int32, Sendable {
        case keepLast = 0
        case keepAll = 1
    }

    package let reliability: Reliability
    package let durability: Durability
    package let historyKind: HistoryKind
    package let historyDepth: Int32

    package init(
        reliability: Reliability = .bestEffort,
        durability: Durability = .volatile,
        historyKind: HistoryKind = .keepLast,
        historyDepth: Int32 = 10
    ) {
        self.reliability = reliability
        self.durability = durability
        self.historyKind = historyKind
        self.historyDepth = historyDepth
    }
}

// MARK: - DDS Error

/// Errors from DDS operations
package enum DDSError: Error, LocalizedError {
    case sessionCreationFailed(String)
    case sessionDestructionFailed(String)
    case writerCreationFailed(String)
    case readerCreationFailed(String)
    case writeFailed(String)
    case notConnected
    case notAvailable

    package var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let msg): return "DDS session creation failed: \(msg)"
        case .sessionDestructionFailed(let msg): return "DDS session destruction failed: \(msg)"
        case .writerCreationFailed(let msg): return "DDS writer creation failed: \(msg)"
        case .readerCreationFailed(let msg): return "DDS reader creation failed: \(msg)"
        case .writeFailed(let msg): return "DDS write failed: \(msg)"
        case .notConnected: return "DDS session not connected"
        case .notAvailable: return "DDS transport not available"
        }
    }
}

// MARK: - DDS Client Protocol

/// Protocol for DDS session management
///
/// Consuming apps implement this by wrapping the CycloneDDS C bridge.
/// swift-ros2's `DDSTransportSession` uses this protocol to create
/// participants, writers, and publish CDR data.
package protocol DDSClientProtocol: AnyObject {
    /// Whether DDS transport is available (compiled with DDS_AVAILABLE)
    var isAvailable: Bool { get }

    /// Create a DDS session (participant + publisher)
    func createSession(domainId: Int32, discoveryConfig: DDSBridgeDiscoveryConfig) throws

    /// Destroy the DDS session
    func destroySession() throws

    /// Check if the session is connected
    func isConnected() -> Bool

    /// Get the session ID as a hex string
    func getSessionId() -> String?

    /// Create a raw CDR writer for a topic
    func createRawWriter(
        topicName: String,
        typeName: String,
        qos: DDSBridgeQoSConfig,
        userData: String?
    ) throws -> any DDSWriterHandle

    /// Write pre-serialized CDR data
    func writeRawCDR(
        writer: any DDSWriterHandle,
        data: Data,
        timestamp: UInt64
    ) throws

    /// Destroy a writer
    func destroyWriter(_ writer: any DDSWriterHandle)

    /// Number of subscriptions currently matched to `writer`, or `nil` when unknown.
    func publicationMatchedCount(writer: any DDSWriterHandle) -> Int?

    /// Create a raw CDR reader for a topic with a per-sample callback.
    ///
    /// - Parameters:
    ///   - topicName: Full DDS topic name (e.g. "rt/chatter").
    ///   - typeName: DDS type name in `::msg::dds_::Type_` form.
    ///   - qos: Reader QoS.
    ///   - userData: USER_DATA QoS string (e.g. "typehash=RIHS01_...;"), or `nil`.
    ///   - handler: Called with the raw CDR payload (including 4-byte XCDR header)
    ///     and the sample source timestamp (nanoseconds since Unix epoch; 0 if the
    ///     publisher did not supply one). Invoked on a CycloneDDS-owned background
    ///     thread — do not block or reentrantly destroy the reader from inside it.
    func createRawReader(
        topicName: String,
        typeName: String,
        qos: DDSBridgeQoSConfig,
        userData: String?,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any DDSReaderHandle

    /// Destroy a reader. Blocks until any in-flight handler invocation completes.
    func destroyReader(_ reader: any DDSReaderHandle)

    /// Whether the given writer currently has any matched subscribers.
    ///
    /// Used by service clients (`waitForService`) to detect server availability.
    /// Conformers that wrap a real DDS bridge should return whatever
    /// `dds_get_publication_matched_status` reports; transports that cannot
    /// determine match state cheaply may keep the default behavior, which
    /// optimistically returns `true` so existing conformers continue to compile
    /// without changes.
    func isPublicationMatched(writer: any DDSWriterHandle) -> Bool

    /// Whether the given reader currently has any matched publications.
    ///
    /// Used by service and action clients (`waitForService` /
    /// `waitForActionServer`) together with ``isPublicationMatched(writer:)``:
    /// a server is only reachable once its reply writer has matched the
    /// client's reply reader too, the same pair of checks as
    /// rmw_cyclonedds_cpp's `rmw_service_server_is_available`. CycloneDDS-backed
    /// conformers return what `dds_get_subscription_matched_status` reports;
    /// the default optimistically returns `true`.
    func isSubscriptionMatched(reader: any DDSReaderHandle) -> Bool
}

extension DDSClientProtocol {
    /// Default: optimistically report the publication as matched. Concrete
    /// conformers (e.g. CycloneDDS-backed bridges) should override this with
    /// `dds_get_publication_matched_status`.
    package func isPublicationMatched(writer: any DDSWriterHandle) -> Bool { true }

    /// Default: optimistically report the subscription as matched. Concrete
    /// conformers (e.g. CycloneDDS-backed bridges) should override this with
    /// `dds_get_subscription_matched_status`.
    package func isSubscriptionMatched(reader: any DDSReaderHandle) -> Bool { true }

    /// Default: unknown. CycloneDDS-backed conformers report the real count.
    package func publicationMatchedCount(writer: any DDSWriterHandle) -> Int? { nil }
}
