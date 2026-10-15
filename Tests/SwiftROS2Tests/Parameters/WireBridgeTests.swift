import RclInterfaces
import XCTest

@testable import SwiftROS2

final class WireBridgeTests: XCTestCase {
    func testNotSetRoundTrip() {
        let swift: ROS2ParameterValue = .notSet
        let wire = swift.toWire()
        XCTAssertEqual(wire.type, 0)
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .notSet)
    }

    func testBoolRoundTrip() {
        let wire = ROS2ParameterValue.bool(true).toWire()
        XCTAssertEqual(wire.type, 1)
        XCTAssertEqual(wire.boolValue, true)
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .bool(true))
    }

    func testIntegerRoundTrip() {
        let wire = ROS2ParameterValue.integer(-42).toWire()
        XCTAssertEqual(wire.type, 2)
        XCTAssertEqual(wire.integerValue, -42)
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .integer(-42))
    }

    func testDoubleRoundTrip() {
        let wire = ROS2ParameterValue.double(3.14).toWire()
        XCTAssertEqual(wire.type, 3)
        XCTAssertEqual(wire.doubleValue, 3.14)
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .double(3.14))
    }

    func testStringRoundTrip() {
        let wire = ROS2ParameterValue.string("hello").toWire()
        XCTAssertEqual(wire.type, 4)
        XCTAssertEqual(wire.stringValue, "hello")
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .string("hello"))
    }

    func testByteArrayRoundTrip() {
        let wire = ROS2ParameterValue.byteArray([1, 2, 3]).toWire()
        XCTAssertEqual(wire.type, 5)
        XCTAssertEqual(wire.byteArrayValue, [1, 2, 3])
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .byteArray([1, 2, 3]))
    }

    func testBoolArrayRoundTrip() {
        let wire = ROS2ParameterValue.boolArray([true, false]).toWire()
        XCTAssertEqual(wire.type, 6)
        XCTAssertEqual(wire.boolArrayValue, [true, false])
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .boolArray([true, false]))
    }

    func testIntegerArrayRoundTrip() {
        let wire = ROS2ParameterValue.integerArray([1, -2]).toWire()
        XCTAssertEqual(wire.type, 7)
        XCTAssertEqual(wire.integerArrayValue, [1, -2])
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .integerArray([1, -2]))
    }

    func testDoubleArrayRoundTrip() {
        let wire = ROS2ParameterValue.doubleArray([1.5, -2.5]).toWire()
        XCTAssertEqual(wire.type, 8)
        XCTAssertEqual(wire.doubleArrayValue, [1.5, -2.5])
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .doubleArray([1.5, -2.5]))
    }

    func testStringArrayRoundTrip() {
        let wire = ROS2ParameterValue.stringArray(["a", "b"]).toWire()
        XCTAssertEqual(wire.type, 9)
        XCTAssertEqual(wire.stringArrayValue, ["a", "b"])
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .stringArray(["a", "b"]))
    }

    func testWireDecodeUnknownTypeFallsBackToNotSet() {
        var wire = RclInterfaces.ParameterValue()
        wire.type = 99
        XCTAssertEqual(ROS2ParameterValue(wire: wire), .notSet)
    }

    func testDescriptorRoundTripWithIntegerRange() {
        let swift = ROS2ParameterDescriptor(
            name: "rate",
            type: .integer,
            description: "publish rate",
            additionalConstraints: "Hz only",
            readOnly: false,
            dynamicTyping: false,
            integerRange: 1...120,
            integerStep: 2
        )
        let wire = swift.toWire()
        XCTAssertEqual(wire.name, "rate")
        XCTAssertEqual(wire.type, 2)
        XCTAssertEqual(wire.description, "publish rate")
        XCTAssertEqual(wire.additionalConstraints, "Hz only")
        XCTAssertFalse(wire.readOnly)
        XCTAssertFalse(wire.dynamicTyping)
        XCTAssertEqual(wire.floatingPointRange.count, 0)
        XCTAssertEqual(wire.integerRange.count, 1)
        XCTAssertEqual(wire.integerRange[0].fromValue, 1)
        XCTAssertEqual(wire.integerRange[0].toValue, 120)
        XCTAssertEqual(wire.integerRange[0].step, 2)

        let back = ROS2ParameterDescriptor(wire: wire)
        XCTAssertEqual(back, swift)
    }

    func testDescriptorRoundTripWithFloatingPointRange() {
        let swift = ROS2ParameterDescriptor(
            name: "gain",
            type: .double,
            floatingPointRange: 0.0...1.0,
            floatingPointStep: 0.1
        )
        let wire = swift.toWire()
        XCTAssertEqual(wire.floatingPointRange.count, 1)
        XCTAssertEqual(wire.floatingPointRange[0].fromValue, 0.0)
        XCTAssertEqual(wire.floatingPointRange[0].toValue, 1.0)
        XCTAssertEqual(wire.floatingPointRange[0].step, 0.1)
        XCTAssertEqual(wire.integerRange.count, 0)

        let back = ROS2ParameterDescriptor(wire: wire)
        XCTAssertEqual(back, swift)
    }

    func testDescriptorRoundTripEmpty() {
        let swift = ROS2ParameterDescriptor()
        let wire = swift.toWire()
        XCTAssertEqual(wire.name, "")
        XCTAssertEqual(wire.type, 0)
        XCTAssertEqual(wire.floatingPointRange.count, 0)
        XCTAssertEqual(wire.integerRange.count, 0)
        XCTAssertEqual(ROS2ParameterDescriptor(wire: wire), swift)
    }

    func testParameterRoundTrip() {
        let swift = ROS2Parameter(name: "rate", value: .integer(30))
        let wire = swift.toWire()
        XCTAssertEqual(wire.name, "rate")
        XCTAssertEqual(wire.value.type, 2)
        XCTAssertEqual(wire.value.integerValue, 30)
        XCTAssertEqual(ROS2Parameter(wire: wire), swift)
    }
}
