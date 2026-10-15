// WireCodec.swift
// QoS policy shared by the wire codecs

import Foundation

/// QoS policy for wire format encoding (transport-agnostic)
package struct QoSPolicy: Sendable, Equatable {
    package enum Reliability: Int, Sendable {
        case bestEffort = 0
        case reliable = 1
    }

    package enum Durability: Int, Sendable {
        case transientLocal = 1
        case volatile = 2
    }

    package enum HistoryPolicy: Int, Sendable {
        case keepLast = 0
        case keepAll = 1
    }

    package var reliability: Reliability
    package var durability: Durability
    package var historyPolicy: HistoryPolicy
    package var historyDepth: Int

    package init(
        reliability: Reliability = .bestEffort,
        durability: Durability = .volatile,
        historyPolicy: HistoryPolicy = .keepLast,
        historyDepth: Int = 10
    ) {
        self.reliability = reliability
        self.durability = durability
        self.historyPolicy = historyPolicy
        self.historyDepth = historyDepth
    }

    /// Encode QoS for liveliness token
    ///
    /// Format: `reliability:durability:history,depth:deadline:lifespan:liveliness`
    ///
    /// This is the encoding of `qos_to_keyexpr` in rmw_zenoh_cpp, which is the same on
    /// Humble, Jazzy, Kilted and Lyrical: a field equal to the rmw_zenoh default is
    /// left empty, any other value is written as its `rmw_qos_*_policy_e` number. The
    /// rmw_zenoh defaults are reliable, volatile and keep-last, so a best-effort
    /// endpoint writes `2` (`RMW_QOS_POLICY_RELIABILITY_BEST_EFFORT`) and a reliable one
    /// writes nothing; a graph tool such as `ros2 topic info -v` reads an empty field
    /// as reliable. Transient-local durability is `1` and keep-all history is `2`.
    package func toKeyExpr() -> String {
        let relStr = reliability == .bestEffort ? "2" : ""
        let durStr = durability == .volatile ? "" : "1"
        let histStr = historyPolicy == .keepLast ? "" : "2"
        let depthStr = String(historyDepth)
        return "\(relStr):\(durStr):\(histStr),\(depthStr):,:,:,,"
    }

    // MARK: - Presets

    package static let sensorData = QoSPolicy(
        reliability: .bestEffort,
        durability: .volatile,
        historyPolicy: .keepLast,
        historyDepth: 10
    )

    package static let latched = QoSPolicy(
        reliability: .reliable,
        durability: .transientLocal,
        historyPolicy: .keepLast,
        historyDepth: 1
    )

    package static let reliableSensor = QoSPolicy(
        reliability: .reliable,
        durability: .volatile,
        historyPolicy: .keepLast,
        historyDepth: 10
    )

    package static let servicesDefault = QoSPolicy(
        reliability: .reliable,
        durability: .volatile,
        historyPolicy: .keepLast,
        historyDepth: 10
    )
}
