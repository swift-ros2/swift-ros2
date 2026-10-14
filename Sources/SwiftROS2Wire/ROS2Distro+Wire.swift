// ROS2Distro+Wire.swift
// Wire-format facts per distribution. The enum itself, with its schema facts, lives in
// SwiftROS2Messages (swift-ros2-rosidl); it is re-exported here so `import SwiftROS2Wire`
// keeps working on its own.

@_exported import enum SwiftROS2Messages.ROS2Distro

extension ROS2Distro {
    /// Wire format group.
    public enum WireGroup: String, CaseIterable, Sendable {
        /// Humble: no type hash in key expressions.
        case legacy = "Humble and earlier"
        /// Iron and later: RIHS01 type hashes.
        case modern = "Iron and later"

        /// The distributions in this group.
        public var distros: [ROS2Distro] {
            ROS2Distro.allCases.filter { $0.wireGroup == self }
        }
    }

    /// The wire format group of this distribution.
    public var wireGroup: WireGroup { isLegacySchema ? .legacy : .modern }

    /// Placeholder written in key expressions for distributions without type hashes.
    public var typeHashPlaceholder: String { "TypeHashNotSupported" }

    /// The type-hash component of a key expression.
    public func formatTypeHash(_ typeHash: String?) -> String {
        supportsTypeHash ? (typeHash ?? "") : typeHashPlaceholder
    }

    /// Whether the key expression always includes the type-hash segment.
    public var alwaysIncludeTypeHashInKey: Bool { isLegacySchema }
}
