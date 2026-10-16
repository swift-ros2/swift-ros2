// ROS2Distro+Wire.swift
// Wire-format facts per distribution. The enum itself, with its schema facts, lives in
// SwiftROS2Messages (swift-ros2-rosidl); it is re-exported here so `import SwiftROS2Wire`
// keeps working on its own.

@_exported import enum SwiftROS2Messages.ROS2Distro

extension ROS2Distro {
    /// Placeholder written in key expressions for distributions without type hashes.
    public var typeHashPlaceholder: String { "TypeHashNotSupported" }

    /// The type-hash component of a key expression.
    public func formatTypeHash(_ typeHash: String?) -> String {
        supportsTypeHash ? (typeHash ?? "") : typeHashPlaceholder
    }

    /// Whether the key expression always includes the type-hash segment.
    public var alwaysIncludeTypeHashInKey: Bool { isLegacySchema }

    /// Whether rmw_zenoh on this distribution routes messages with `uint8[]` fields
    /// through buffer endpoints (Lyrical and later): a publisher sends only to the
    /// subscriptions it discovers, and to CPU-only ones on `<key>/_buf_cpu`.
    public var usesZenohBufferEndpoints: Bool {
        switch self {
        case .humble, .jazzy, .kilted: return false
        default: return true
        }
    }
}
