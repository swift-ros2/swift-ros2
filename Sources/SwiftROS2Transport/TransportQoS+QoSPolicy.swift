// TransportQoS+QoSPolicy.swift
// Conversion from TransportQoS to wire-level QoSPolicy.

import SwiftROS2Wire

extension TransportQoS {
    /// Convert to wire-level QoSPolicy for liveliness token encoding
    package func toQoSPolicy() -> QoSPolicy {
        TransportQoSMapper.toWireQoSPolicy(self)
    }
}
