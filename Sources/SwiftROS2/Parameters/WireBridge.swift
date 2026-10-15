// Translation between the Swift-public ROS2* types and the
// RclInterfaces wire types. The wire types use
// uint8 discriminators + fixed-name typed slots; we hide that here.

import RclInterfaces

extension ROS2ParameterValue {
    init(wire: RclInterfaces.ParameterValue) {
        switch wire.type {
        case 1: self = .bool(wire.boolValue)
        case 2: self = .integer(wire.integerValue)
        case 3: self = .double(wire.doubleValue)
        case 4: self = .string(wire.stringValue)
        case 5: self = .byteArray(wire.byteArrayValue)
        case 6: self = .boolArray(wire.boolArrayValue)
        case 7: self = .integerArray(wire.integerArrayValue)
        case 8: self = .doubleArray(wire.doubleArrayValue)
        case 9: self = .stringArray(wire.stringArrayValue)
        default: self = .notSet
        }
    }

    func toWire() -> RclInterfaces.ParameterValue {
        var w = RclInterfaces.ParameterValue()
        switch self {
        case .notSet:
            w.type = 0
        case .bool(let v):
            w.type = 1
            w.boolValue = v
        case .integer(let v):
            w.type = 2
            w.integerValue = v
        case .double(let v):
            w.type = 3
            w.doubleValue = v
        case .string(let v):
            w.type = 4
            w.stringValue = v
        case .byteArray(let v):
            w.type = 5
            w.byteArrayValue = v
        case .boolArray(let v):
            w.type = 6
            w.boolArrayValue = v
        case .integerArray(let v):
            w.type = 7
            w.integerArrayValue = v
        case .doubleArray(let v):
            w.type = 8
            w.doubleArrayValue = v
        case .stringArray(let v):
            w.type = 9
            w.stringArrayValue = v
        }
        return w
    }
}

extension ROS2ParameterDescriptor {
    // The wire `IntegerRange.step` is `uint64`; our `integerStep` is
    // `Int64?` to match Swift convention. We round-trip through the bit
    // pattern so the encode/decode pair is lossless even for negative
    // step values (which are nonsensical but valid on the wire).
    init(wire: RclInterfaces.ParameterDescriptor) {
        let floating = wire.floatingPointRange.first
        let integer = wire.integerRange.first
        self.init(
            name: wire.name,
            type: ROS2ParameterType(rawValue: wire.type) ?? .notSet,
            description: wire.description,
            additionalConstraints: wire.additionalConstraints,
            readOnly: wire.readOnly,
            dynamicTyping: wire.dynamicTyping,
            floatingPointRange: floating.map { $0.fromValue...$0.toValue },
            floatingPointStep: floating.map { $0.step },
            integerRange: integer.map { $0.fromValue...$0.toValue },
            integerStep: integer.map { Int64(bitPattern: $0.step) }
        )
    }

    // Step is meaningful only paired with a range. The wire's `IntegerRange` /
    // `FloatingPointRange` carries from/to/step together — there is no slot
    // for a free-standing step. If the caller sets a step but no range,
    // the step is intentionally not encoded; document via the type rather
    // than asserting at runtime.
    func toWire() -> RclInterfaces.ParameterDescriptor {
        var w = RclInterfaces.ParameterDescriptor()
        w.name = name
        w.type = type.rawValue
        w.description = description
        w.additionalConstraints = additionalConstraints
        w.readOnly = readOnly
        w.dynamicTyping = dynamicTyping
        if let r = floatingPointRange {
            w.floatingPointRange = [
                RclInterfaces.FloatingPointRange(
                    fromValue: r.lowerBound,
                    toValue: r.upperBound,
                    step: floatingPointStep ?? 0.0
                )
            ]
        }
        if let r = integerRange {
            w.integerRange = [
                RclInterfaces.IntegerRange(
                    fromValue: r.lowerBound,
                    toValue: r.upperBound,
                    step: integerStep.map { UInt64(bitPattern: $0) } ?? 0
                )
            ]
        }
        return w
    }
}

extension ROS2Parameter {
    init(wire: RclInterfaces.Parameter) {
        self.init(name: wire.name, value: ROS2ParameterValue(wire: wire.value))
    }

    func toWire() -> RclInterfaces.Parameter {
        RclInterfaces.Parameter(name: name, value: value.toWire())
    }
}
