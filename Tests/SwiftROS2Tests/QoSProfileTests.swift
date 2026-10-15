import SwiftROS2
import SwiftROS2Transport
import XCTest

final class QoSProfileTests: XCTestCase {
    // MARK: - presets

    func testSensorDataPreset() {
        XCTAssertEqual(QoSProfile.sensorData.reliability, .bestEffort)
        XCTAssertEqual(QoSProfile.sensorData.durability, .volatile)
        XCTAssertEqual(QoSProfile.sensorData.history, .keepLast(10))
    }

    func testReliableSensorPreset() {
        XCTAssertEqual(QoSProfile.reliableSensor.reliability, .reliable)
        XCTAssertEqual(QoSProfile.reliableSensor.durability, .volatile)
        XCTAssertEqual(QoSProfile.reliableSensor.history, .keepLast(10))
    }

    func testLatchedPreset() {
        XCTAssertEqual(QoSProfile.latched.reliability, .reliable)
        XCTAssertEqual(QoSProfile.latched.durability, .transientLocal)
        XCTAssertEqual(QoSProfile.latched.history, .keepLast(1))
    }

    func testServicesDefaultPreset() {
        XCTAssertEqual(QoSProfile.servicesDefault.reliability, .reliable)
        XCTAssertEqual(QoSProfile.servicesDefault.durability, .volatile)
    }

    func testParameterEventsPreset() {
        let q = QoSProfile.parameterEvents
        XCTAssertEqual(q.reliability, .reliable)
        XCTAssertEqual(q.durability, .transientLocal)
        if case .keepLast(let depth) = q.history {
            XCTAssertEqual(depth, 1000)
        } else {
            XCTFail("expected keepLast(1000), got \(q.history)")
        }
    }

    func testDefaultIsSensorData() {
        XCTAssertEqual(QoSProfile.default, QoSProfile.sensorData)
    }

    // MARK: - equatability

    func testProfilesAreEqualWhenAllFieldsMatch() {
        XCTAssertEqual(
            QoSProfile(reliability: .reliable, durability: .volatile, history: .keepLast(5)),
            QoSProfile(reliability: .reliable, durability: .volatile, history: .keepLast(5))
        )
    }

    func testProfilesDifferOnHistoryDepth() {
        XCTAssertNotEqual(
            QoSProfile(history: .keepLast(5)),
            QoSProfile(history: .keepLast(6))
        )
    }

    // MARK: - toTransportQoS

    func testToTransportQoSPreservesReliability() {
        let profile = QoSProfile(reliability: .reliable, durability: .volatile, history: .keepLast(10))
        XCTAssertEqual(profile.toTransportQoS().reliability, .reliable)
    }

    func testToTransportQoSMapsKeepAll() {
        let profile = QoSProfile(reliability: .reliable, durability: .volatile, history: .keepAll)
        let qos = profile.toTransportQoS()
        if case .keepAll = qos.history {
            // ok
        } else {
            XCTFail("Expected keepAll")
        }
    }
}
