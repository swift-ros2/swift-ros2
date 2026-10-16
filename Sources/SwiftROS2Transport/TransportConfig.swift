// TransportConfig.swift
// Transport configuration types

import Foundation
import SwiftROS2Wire

// MARK: - Transport Type

/// The underlying transport mechanism used to connect to ROS 2.
///
/// Choose `.zenoh` for cross-platform support (including mobile and desktop),
/// `.dds` for direct CycloneDDS communication on Apple platforms and Linux, or
/// `.rcl` for the native rcl backend with `rmw_cyclonedds_cpp` (built by
/// default on Apple platforms — opt out with `SWIFT_ROS2_DISABLE_RCL=1` — and
/// opt-in via `SWIFT_ROS2_ENABLE_RCL=1` on Linux).
///
/// `allCases` always includes `.rcl`, even on build graphs where
/// `ROS2Context(transport:)` throws ``TransportError/unsupportedFeature(_:)``
/// for it (Windows, Android, Linux without RCL, Apple with
/// `SWIFT_ROS2_DISABLE_RCL=1` or `SWIFT_ROS2_RCL_RMW=zenoh`).
public enum TransportType: String, Codable, CaseIterable, Sendable {
    case zenoh
    case dds
    case rcl

    public var displayName: String {
        switch self {
        case .zenoh: return "Zenoh"
        case .dds: return "DDS"
        case .rcl: return "RCL (DDS)"
        }
    }
}

// MARK: - DDS Discovery Mode

/// How CycloneDDS discovers remote participants on the network.
///
/// Use `.multicast` on networks that support it, `.unicast` when multicast is blocked
/// (common on Wi-Fi), or `.hybrid` to try multicast first and fall back to unicast.
public enum DDSDiscoveryMode: String, Codable, CaseIterable, Sendable {
    case multicast
    case unicast
    case hybrid

    public var requiresPeerConfiguration: Bool {
        switch self {
        case .multicast: return false
        case .unicast, .hybrid: return true
        }
    }
}

// MARK: - DDS Peer

/// A remote DDS participant identified by IP address and UDP port.
///
/// Used to configure unicast or hybrid DDS discovery when multicast is unavailable.
/// The discovery port follows the CycloneDDS formula: `7400 + domainId * 250`.
public struct DDSPeer: Codable, Equatable, Sendable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16 = 7400) {
        self.address = address
        self.port = port
    }

    public var locator: String {
        "udp/\(address):\(port)"
    }

    /// The peer as CycloneDDS consumes it in `<Peer address="..."/>` — always
    /// `host:port`, with a bare IPv6 address bracketed.
    ///
    /// The port is not optional decoration. CycloneDDS only sends SPDP to the
    /// exact port when the peer string carries one; a bare host makes it patch
    /// in the *participant* unicast discovery port (`7400 + 250 * domain + 10`)
    /// and probe participant indices up to `MaxAutoParticipantIndex` — 7410,
    /// 7412, ... 7426 on domain 0. Nothing is bound there when the remote runs
    /// the default `ParticipantIndex` ("none", which leaves its unicast ports
    /// ephemeral), so discovery silently never completes (issue #176).
    ///
    /// Bracketing matters for the same reason: `ddsi_ipaddr_from_string` only
    /// reads a port off an IPv6 address when the address part is bracketed, so
    /// `fe80::1:7400` would parse as a *different* address with no port.
    public var discoveryAddress: String {
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return "\(host):\(port)"
    }

    /// The `<Peer address="..."/>` entries this peer becomes: `host:port`, then
    /// the bare host.
    ///
    /// `host:port` alone is not enough. On the shared discovery port every
    /// participant of a Linux host binds the same UDP port with address reuse,
    /// and the kernel hands a unicast datagram to the most recently bound socket
    /// only, so only the newest participant on that host would ever discover us
    /// (youtalk/conduit#123). The bare host makes CycloneDDS also send SPDP to
    /// each participant index's own unicast port (`7400 + 250 * domain + 10 +
    /// 2 * index`, up to `MaxAutoParticipantIndex`), which reaches every
    /// participant that has an index, as rmw_cyclonedds_cpp's do. The
    /// `host:port` entry still reaches a participant without an index (#176).
    package var discoveryAddresses: [String] {
        let bare =
            address.hasPrefix("[") && address.hasSuffix("]")
            ? String(address.dropFirst().dropLast()) : address
        return [discoveryAddress, bare]
    }

    public static func discoveryPort(forDomain domainId: Int) -> UInt16 {
        UInt16(7400 + domainId * 250)
    }

    public static func peer(address: String, domainId: Int) -> DDSPeer {
        DDSPeer(address: address, port: discoveryPort(forDomain: domainId))
    }
}

// MARK: - Transport Configuration

/// Complete configuration for a transport session, covering both Zenoh and DDS parameters.
///
/// Construct instances using the static factory methods ``zenoh(locator:domainId:wireMode:connectionTimeout:)``,
/// ``ddsMulticast(domainId:)``, or ``ddsUnicast(peers:domainId:)`` rather than the memberwise initializer.
public struct TransportConfig: Sendable {
    public let type: TransportType
    public let domainId: Int

    // Zenoh-specific
    public let zenohLocator: String?
    /// The distribution whose wire format the session speaks, or `nil` to take the
    /// context's `distro`.
    ///
    /// `ROS2Context(transport:distro:)` fills in its `distro` when this is `nil`, so
    /// leaving it unset is the usual choice. An explicit value takes precedence over
    /// `distro` for the wire format of the session: the Zenoh key expressions and
    /// liveliness tokens and, on the wire DDS transport, the layout of the
    /// `ros_discovery_info` record. `distro` stays what decides the type-hash and
    /// schema handling of the entities, so the context logs a warning when the two
    /// differ.
    public let wireMode: ROS2Distro?
    public let connectionTimeout: TimeInterval

    // DDS-specific
    public let ddsDiscoveryMode: DDSDiscoveryMode
    public let ddsUnicastPeers: [DDSPeer]
    public let ddsNetworkInterface: String?

    /// A Zenoh configuration.
    ///
    /// - Parameter wireMode: Leave `nil` to use the `distro` of the ``ROS2Context``. An
    ///   explicit value overrides `distro` for the wire format; see ``wireMode``.
    public static func zenoh(
        locator: String,
        domainId: Int = 0,
        wireMode: ROS2Distro? = nil,
        connectionTimeout: TimeInterval = 10.0
    ) -> TransportConfig {
        TransportConfig(
            type: .zenoh, domainId: domainId,
            zenohLocator: locator, wireMode: wireMode,
            connectionTimeout: connectionTimeout,
            ddsDiscoveryMode: .multicast, ddsUnicastPeers: [], ddsNetworkInterface: nil
        )
    }

    public static func ddsMulticast(domainId: Int = 0) -> TransportConfig {
        TransportConfig(
            type: .dds, domainId: domainId,
            zenohLocator: nil, wireMode: nil, connectionTimeout: 10.0,
            ddsDiscoveryMode: .multicast, ddsUnicastPeers: [], ddsNetworkInterface: nil
        )
    }

    public static func ddsUnicast(peers: [DDSPeer], domainId: Int = 0) -> TransportConfig {
        TransportConfig(
            type: .dds, domainId: domainId,
            zenohLocator: nil, wireMode: nil, connectionTimeout: 10.0,
            ddsDiscoveryMode: .unicast, ddsUnicastPeers: peers, ddsNetworkInterface: nil
        )
    }

    /// RCL + `rmw_cyclonedds_cpp` backend.
    ///
    /// Requires the RCL backend with the `rmw_cyclonedds_cpp` rmw in the build:
    /// on by default on Apple platforms (prebuilt CRos2 xcframework; not
    /// with `SWIFT_ROS2_DISABLE_RCL=1` or `SWIFT_ROS2_RCL_RMW=zenoh`), opt-in via
    /// `SWIFT_ROS2_ENABLE_RCL=1` on Linux (system ROS 2 install, see
    /// `ROS2_RCL_PREFIX`). On other configurations, `ROS2Context(transport:)`
    /// throws ``TransportError/unsupportedFeature(_:)``.
    public static func rcl(domainId: Int = 0) -> TransportConfig {
        TransportConfig(
            type: .rcl, domainId: domainId,
            zenohLocator: nil, wireMode: nil, connectionTimeout: 10.0,
            ddsDiscoveryMode: .multicast, ddsUnicastPeers: [], ddsNetworkInterface: nil
        )
    }

    /// RCL transport with explicit unicast discovery (CycloneDDS static peers)
    /// and an optional network interface. On the RCL backend these are exported
    /// as CYCLONEDDS_URI for rmw_cyclonedds (see RclClient.createContext).
    ///
    /// Pinning only a `interface` (no `peers`) is a valid discovery config —
    /// the NIC is pinned while SPDP stays multicast — so it resolves to
    /// `.multicast` and passes `validate()`. `peers: []` with no `interface`
    /// keeps `.unicast`, which `validate()` rejects as an empty discovery
    /// config. The discovery XML the RCL backend exports is derived from
    /// `peers`/`interface` directly, not from this mode.
    public static func rclUnicast(
        peers: [DDSPeer], domainId: Int = 0, interface: String? = nil
    ) -> TransportConfig {
        let mode: DDSDiscoveryMode = peers.isEmpty && interface != nil ? .multicast : .unicast
        return TransportConfig(
            type: .rcl, domainId: domainId,
            ddsDiscoveryMode: mode, ddsUnicastPeers: peers,
            ddsNetworkInterface: interface)
    }

    public init(
        type: TransportType,
        domainId: Int = 0,
        zenohLocator: String? = nil,
        wireMode: ROS2Distro? = nil,
        connectionTimeout: TimeInterval = 10.0,
        ddsDiscoveryMode: DDSDiscoveryMode = .multicast,
        ddsUnicastPeers: [DDSPeer] = [],
        ddsNetworkInterface: String? = nil
    ) {
        self.type = type
        self.domainId = domainId
        self.zenohLocator = zenohLocator
        self.wireMode = wireMode
        self.connectionTimeout = connectionTimeout
        self.ddsDiscoveryMode = ddsDiscoveryMode
        self.ddsUnicastPeers = ddsUnicastPeers
        self.ddsNetworkInterface = ddsNetworkInterface
    }

    /// This configuration with `wireMode` set to `distro` when it has none.
    ///
    /// A Zenoh session without a wire mode falls back to the Jazzy wire, so a context
    /// passes its distribution here: Lyrical and later need distribution-specific
    /// handling (see ``ROS2Distro/usesZenohBufferEndpoints``).
    package func withDefaultWireMode(_ distro: ROS2Distro) -> TransportConfig {
        guard wireMode == nil else { return self }
        return TransportConfig(
            type: type, domainId: domainId, zenohLocator: zenohLocator, wireMode: distro,
            connectionTimeout: connectionTimeout, ddsDiscoveryMode: ddsDiscoveryMode,
            ddsUnicastPeers: ddsUnicastPeers, ddsNetworkInterface: ddsNetworkInterface)
    }

    public func validate() throws {
        guard domainId >= 0 && domainId <= 232 else {
            throw TransportError.invalidConfiguration("Domain ID must be 0-232, got \(domainId)")
        }
        switch type {
        case .zenoh:
            guard let locator = zenohLocator, !locator.isEmpty else {
                throw TransportError.invalidConfiguration("Zenoh transport requires a router locator")
            }
        case .dds:
            if ddsDiscoveryMode.requiresPeerConfiguration && ddsUnicastPeers.isEmpty {
                throw TransportError.invalidConfiguration("DDS \(ddsDiscoveryMode) mode requires peer configuration")
            }
        case .rcl:
            if ddsDiscoveryMode.requiresPeerConfiguration && ddsUnicastPeers.isEmpty {
                throw TransportError.invalidConfiguration(
                    "RCL \(ddsDiscoveryMode) mode requires peer configuration")
            }
        }
    }
}

// MARK: - Domain override

extension TransportConfig {
    /// This configuration moved to `newDomainId`, as `ROS2Context` opens it when
    /// its `domainId` argument is given.
    ///
    /// Every field is kept except the domain, and except unicast peers on the
    /// discovery port of the current domain (`7400 + 250 × domainId`, which
    /// includes `DDSPeer(address:)`'s default 7400 on domain 0): those move to
    /// the discovery port of `newDomainId`, where the remote participants of
    /// that domain listen. Peers on any other port are kept as they are.
    /// An out-of-range `newDomainId` is kept as is for `validate()` to reject.
    package func withDomainId(_ newDomainId: Int) -> TransportConfig {
        guard newDomainId != domainId else { return self }
        var peers = ddsUnicastPeers
        if let oldPort = Self.discoveryPortIfValid(forDomain: domainId),
            let newPort = Self.discoveryPortIfValid(forDomain: newDomainId)
        {
            peers = peers.map { $0.port == oldPort ? DDSPeer(address: $0.address, port: newPort) : $0 }
        }
        return TransportConfig(
            type: type,
            domainId: newDomainId,
            zenohLocator: zenohLocator,
            wireMode: wireMode,
            connectionTimeout: connectionTimeout,
            ddsDiscoveryMode: ddsDiscoveryMode,
            ddsUnicastPeers: peers,
            ddsNetworkInterface: ddsNetworkInterface
        )
    }

    private static func discoveryPortIfValid(forDomain domainId: Int) -> UInt16? {
        (0...232).contains(domainId) ? DDSPeer.discoveryPort(forDomain: domainId) : nil
    }
}
