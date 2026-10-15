// QoSProfile.swift
// ROS 2 Quality of Service profiles

import Foundation
import SwiftROS2Transport

/// ROS 2 QoS profile for publishers and subscribers
public struct QoSProfile: Sendable, Equatable {
    public enum Reliability: Sendable, Equatable {
        case reliable
        case bestEffort
    }

    public enum Durability: Sendable, Equatable {
        case volatile
        case transientLocal
    }

    public enum History: Sendable, Equatable {
        case keepLast(Int)
        case keepAll
    }

    public let reliability: Reliability
    public let durability: Durability
    public let history: History

    public init(
        reliability: Reliability = .bestEffort,
        durability: Durability = .volatile,
        history: History = .keepLast(10)
    ) {
        self.reliability = reliability
        self.durability = durability
        self.history = history
    }

    // MARK: - Presets

    /// Default for sensor data (best effort, volatile, keep last 10)
    public static let sensorData = QoSProfile(
        reliability: .bestEffort,
        durability: .volatile,
        history: .keepLast(10)
    )

    /// Reliable sensor data
    public static let reliableSensor = QoSProfile(
        reliability: .reliable,
        durability: .volatile,
        history: .keepLast(10)
    )

    /// Latched topic (reliable, transient local, keep last 1)
    public static let latched = QoSProfile(
        reliability: .reliable,
        durability: .transientLocal,
        history: .keepLast(1)
    )

    /// `rmw_qos_profile_parameter_events` — reliable, transient-local,
    /// keep-last 1000. Used by the `/parameter_events` topic so a late-
    /// joining subscriber sees recent events. Do not reduce the depth.
    public static let parameterEvents = QoSProfile(
        reliability: .reliable,
        durability: .transientLocal,
        history: .keepLast(1000)
    )

    /// Default for services
    public static let servicesDefault = QoSProfile(
        reliability: .reliable,
        durability: .volatile,
        history: .keepLast(10)
    )

    /// Default QoS for ROS 2 Action services and topics.
    ///
    /// Reliable, volatile, keep-last 10 — matches rclcpp's
    /// `rmw_qos_profile_services_default` for the three service roles. The
    /// status topic is bumped to `transientLocal` keep-last 1 inside the
    /// transport layer.
    public static let actionDefault = QoSProfile(
        reliability: .reliable,
        durability: .volatile,
        history: .keepLast(10)
    )

    /// Default profile
    public static let `default` = sensorData

    // MARK: - Conversion

    /// Convert to transport-level QoS
    package func toTransportQoS() -> TransportQoS {
        let rel: TransportQoS.Reliability = reliability == .reliable ? .reliable : .bestEffort
        let dur: TransportQoS.Durability = durability == .transientLocal ? .transientLocal : .volatile
        let hist: TransportQoS.History
        switch history {
        case .keepLast(let n): hist = .keepLast(n)
        case .keepAll: hist = .keepAll
        }
        return TransportQoS(reliability: rel, durability: dur, history: hist)
    }
}
