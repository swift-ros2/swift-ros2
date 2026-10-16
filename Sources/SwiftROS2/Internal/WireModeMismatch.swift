// WireModeMismatch.swift
// Detects and logs a ROS2Context whose transport wireMode differs from its distro.

import Foundation
import SwiftROS2Wire

#if canImport(os)
    import os
#endif

/// The check that warns when a context's explicit `TransportConfig.wireMode` and its `distro`
/// name different distributions.
///
/// The two are separate on purpose: an explicit `wireMode` decides the wire format of the
/// session (the Zenoh key expressions and liveliness tokens, the layout of the DDS
/// `ros_discovery_info` record), while `distro` is the default for it and still decides the
/// type-hash and schema handling of the nodes' entities. A mix is legal, but it is rarely what
/// the caller meant, and the symptom (a host that sees the topic and receives nothing) is silent.
enum WireModeMismatch {
    /// The log line for a context created with `wireMode` and `distro`, or `nil` when there is
    /// nothing to report: no explicit `wireMode`, or one equal to `distro`.
    static func warning(wireMode: ROS2Distro?, distro: ROS2Distro) -> String? {
        guard let wireMode, wireMode != distro else { return nil }
        return "ROS2Context was created with TransportConfig.wireMode \(wireMode) and distro "
            + "\(distro). The wireMode decides the wire format of the session (Zenoh key "
            + "expressions and tokens, DDS ros_discovery_info), and the distro still decides the type "
            + "hash and schema handling of the entities. Pass the host's distribution as both, or "
            + "leave wireMode unset."
    }

    /// The default sink: the unified log on Apple platforms, standard error elsewhere.
    static let logToSystem: @Sendable (String) -> Void = { line in
        #if canImport(os)
            contextLogger.warning("\(line, privacy: .public)")
        #else
            FileHandle.standardError.write(Data("swift-ros2: warning: \(line)\n".utf8))
        #endif
    }
}

#if canImport(os)
    private let contextLogger = Logger(subsystem: "com.youtalk.swift-ros2", category: "Context")
#endif
