// RclInterfaceTypesupportGateTests.swift
// A service or action type missing from the bundled srv / action registry
// throws the same TransportError.unsupportedFeature a topic of an unbundled
// type throws, on every rmw variant (services and actions have no raw-CDR
// fallback).

#if SWIFT_ROS2_RCL
    import Foundation
    import SwiftROS2RCL
    import SwiftROS2Transport
    import XCTest

    /// Stand-in node handle: the gate fires before the node handle is
    /// inspected, so these tests need no rcl context or node.
    private final class FakeNodeHandle: RclNodeHandle {}

    final class RclInterfaceTypesupportGateTests: XCTestCase {
        private let absentService = "foo_msgs/srv/Bar"
        private let absentAction = "foo_msgs/action/Bar"

        private func assertUnsupported(_ error: Error, _ typeName: String) {
            guard case TransportError.unsupportedFeature(let message) = error else {
                return XCTFail("expected unsupportedFeature, got \(error)")
            }
            XCTAssertTrue(message.contains(typeName), "type name missing from: \(message)")
        }

        private func assertInvalidNode(_ error: Error) {
            guard case TransportError.subscriberCreationFailed(let message) = error else {
                return XCTFail("expected subscriberCreationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("invalid node handle"), "unexpected: \(message)")
        }

        private func serviceServer(_ type: String) throws {
            _ = try RclClient().createServiceServer(
                node: FakeNodeHandle(), srvTypeName: type, serviceName: "/gate_srv",
                qos: .default, onRequest: { _, _ in })
        }

        private func serviceClient(_ type: String) throws {
            _ = try RclClient().createServiceClient(
                node: FakeNodeHandle(), srvTypeName: type, serviceName: "/gate_srv",
                qos: .default, onResponse: { _, _ in })
        }

        private func actionServer(_ type: String) throws {
            _ = try RclClient().createActionServer(
                node: FakeNodeHandle(), actionTypeName: type, actionName: "/gate_action",
                qos: .default,
                callbacks: RclActionServerCallbacks(
                    onGoalRequest: { _, _ in }, onCancelRequest: { _, _ in },
                    onResultRequest: { _, _ in }))
        }

        private func actionClient(_ type: String) throws {
            _ = try RclClient().createActionClient(
                node: FakeNodeHandle(), actionTypeName: type, actionName: "/gate_action",
                qos: .default,
                callbacks: RclActionClientCallbacks(
                    onGoalResponse: { _, _ in }, onCancelResponse: { _, _ in },
                    onResultResponse: { _, _ in }, onFeedback: { _ in }, onStatus: { _ in }))
        }

        func testUnbundledServiceTypeThrowsUnsupportedFeature() {
            XCTAssertThrowsError(try serviceServer(absentService)) { assertUnsupported($0, absentService) }
            XCTAssertThrowsError(try serviceClient(absentService)) { assertUnsupported($0, absentService) }
        }

        func testUnbundledActionTypeThrowsUnsupportedFeature() {
            XCTAssertThrowsError(try actionServer(absentAction)) { assertUnsupported($0, absentAction) }
            XCTAssertThrowsError(try actionClient(absentAction)) { assertUnsupported($0, absentAction) }
        }

        func testBundledTypesPassTheGate() {
            // A bundled type gets past the gate and fails on the fake node handle.
            let service = "example_interfaces/srv/AddTwoInts"
            let action = "example_interfaces/action/Fibonacci"
            XCTAssertThrowsError(try serviceServer(service)) { assertInvalidNode($0) }
            XCTAssertThrowsError(try serviceClient(service)) { assertInvalidNode($0) }
            XCTAssertThrowsError(try actionServer(action)) { assertInvalidNode($0) }
            XCTAssertThrowsError(try actionClient(action)) { assertInvalidNode($0) }
        }
    }
#endif
