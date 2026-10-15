import Foundation
import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

/// Parameters verification, mock-seam half: default `ROS2NodeOptions` on
/// the `.rcl` transport must register the six rcl_interfaces parameter
/// services and route `/parameter_events` through the serialized publisher
/// seam — with zero parameter-specific transport work. Backed by a recording
/// `RclClientProtocol` mock (no xcframework, no SWIFT_ROS2_RCL), so this
/// guards the wiring in ordinary CI; the live half is the crcl-svc-loopback
/// gate plus `RclParameterIntegrationTests`.
final class RclParameterStackTests: XCTestCase {
    private func makeRclContext() async throws -> (ROS2Context, RecordingRclSeamClient) {
        let seam = RecordingRclSeamClient()
        let session = RclTransportSession(client: seam)
        let ctx = try await ROS2Context(transport: .rcl(domainId: 0), session: session)
        return (ctx, seam)
    }

    func testDefaultCreateNodeRegistersSixParameterServicesOnRclSeam() async throws {
        let (ctx, seam) = try await makeRclContext()
        defer { Task { await ctx.shutdown() } }
        _ = try await ctx.createNode(name: "param_node", namespace: "/t")

        let created = seam.servicesCreated
        XCTAssertEqual(created.count, 6)
        // Assert (name, type) as pairs so crossed name-to-type wiring fails too.
        XCTAssertEqual(
            Set(created.map { "\($0.serviceName)|\($0.srvTypeName)" }),
            [
                "/t/param_node/get_parameters|rcl_interfaces/srv/GetParameters",
                "/t/param_node/get_parameter_types|rcl_interfaces/srv/GetParameterTypes",
                "/t/param_node/set_parameters|rcl_interfaces/srv/SetParameters",
                "/t/param_node/set_parameters_atomically|rcl_interfaces/srv/SetParametersAtomically",
                "/t/param_node/list_parameters|rcl_interfaces/srv/ListParameters",
                "/t/param_node/describe_parameters|rcl_interfaces/srv/DescribeParameters",
            ])
    }

    func testDeclareParameterOnRclSeamDoesNotThrowAndPublishesEvent() async throws {
        let (ctx, seam) = try await makeRclContext()
        defer { Task { await ctx.shutdown() } }
        let node = try await ctx.createNode(name: "param_node", namespace: "/t")

        let declared = try await node.declareParameter("rate", default: Int64(30))
        XCTAssertEqual(declared, 30)

        // The lazy /parameter_events publisher is created (and the declare
        // event emitted) from a detached Task — poll with a bounded deadline,
        // same idiom as ParameterEventTests.waitForEvents.
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if !seam.publishedPayloads.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(seam.publishersCreated.count, 1)
        XCTAssertEqual(seam.publishersCreated.first?.topic, "/parameter_events")
        XCTAssertEqual(
            seam.publishersCreated.first?.typeName, "rcl_interfaces/msg/ParameterEvent")
        XCTAssertEqual(seam.publishedPayloads.count, 1)
    }
}

// MARK: - Recording rcl seam mock

private final class SeamNode: RclNodeHandle, @unchecked Sendable {
    let name: String
    init(name: String) { self.name = name }
}

private final class SeamPublisher: RclPublisherHandle, @unchecked Sendable {
    var isActive: Bool { true }
    func close() {}
}

private final class SeamSubscription: RclSubscriptionHandle, @unchecked Sendable {
    var isActive: Bool { true }
}

private final class SeamService: RclServiceHandle, @unchecked Sendable {
    var isActive: Bool { true }
}

private final class SeamServiceClient: RclClientHandle, @unchecked Sendable {
    var isActive: Bool { true }
}

private final class SeamActionServer: RclActionServerHandle, @unchecked Sendable {
    var isActive: Bool { true }
}

private final class SeamActionClient: RclActionClientHandle, @unchecked Sendable {
    var isActive: Bool { true }
}

/// Minimal `RclClientProtocol` recorder: enough to observe what the default
/// `createNode` path creates on the seam. Distinct from the transport-layer
/// `MockRclClient` (a different test target), and intentionally thinner — no
/// fire hooks, no failure injection.
private final class RecordingRclSeamClient: RclClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isAvailable: Bool { true }

    private var _publishersCreated: [(topic: String, typeName: String)] = []
    private var _publishedPayloads: [Data] = []
    private var _servicesCreated: [(serviceName: String, srvTypeName: String)] = []

    var publishersCreated: [(topic: String, typeName: String)] {
        sync { _publishersCreated }
    }
    var publishedPayloads: [Data] {
        sync { _publishedPayloads }
    }
    var servicesCreated: [(serviceName: String, srvTypeName: String)] {
        sync { _servicesCreated }
    }

    func createContext(
        domainId: Int32, transportType: TransportType, unicastPeerAddresses: [String],
        networkInterface: String?, zenohRouterLocator: String?
    ) throws {}
    func destroyContext() {}

    func createNode(name: String, namespace: String) throws -> any RclNodeHandle {
        SeamNode(name: name)
    }
    func destroyNode(_ node: any RclNodeHandle) {}

    func createPublisher(
        node: any RclNodeHandle, typeName: String, typeHash: String?, topic: String,
        qos: TransportQoS
    ) throws -> any RclPublisherHandle {
        sync { _publishersCreated.append((topic, typeName)) }
        return SeamPublisher()
    }

    func publishSerialized(_ publisher: any RclPublisherHandle, data: Data) throws {
        sync { _publishedPayloads.append(data) }
    }

    func createSubscription(
        node: any RclNodeHandle, typeName: String, typeHash: String?, topic: String,
        qos: TransportQoS, handler: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> any RclSubscriptionHandle {
        SeamSubscription()
    }
    func destroySubscription(_ subscription: any RclSubscriptionHandle) {}

    func createServiceServer(
        node: any RclNodeHandle, srvTypeName: String, serviceName: String, qos: TransportQoS,
        onRequest: @escaping @Sendable (Data, [UInt8]) -> Void
    ) throws -> any RclServiceHandle {
        sync { _servicesCreated.append((serviceName, srvTypeName)) }
        return SeamService()
    }
    func sendResponse(_ service: any RclServiceHandle, requestId: [UInt8], data: Data) throws {}
    func destroyServiceServer(_ service: any RclServiceHandle) {}

    func createServiceClient(
        node: any RclNodeHandle, srvTypeName: String, serviceName: String, qos: TransportQoS,
        onResponse: @escaping @Sendable (Int64, Data) -> Void
    ) throws -> any RclClientHandle {
        SeamServiceClient()
    }
    func sendRequest(_ client: any RclClientHandle, data: Data) throws -> Int64 { 1 }
    func serverAvailable(_ client: any RclClientHandle) -> Bool { true }
    func destroyServiceClient(_ client: any RclClientHandle) {}

    func createActionServer(
        node: any RclNodeHandle, actionTypeName: String, actionName: String, qos: TransportQoS,
        callbacks: RclActionServerCallbacks
    ) throws -> any RclActionServerHandle {
        SeamActionServer()
    }
    func sendGoalResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws
    {}
    func sendCancelResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws
    {}
    func sendResultResponse(_ server: any RclActionServerHandle, requestId: [UInt8], data: Data)
        throws
    {}
    func publishActionFeedback(_ server: any RclActionServerHandle, data: Data) throws {}
    func publishActionStatus(_ server: any RclActionServerHandle) throws {}
    func acceptGoal(
        _ server: any RclActionServerHandle, goalId: [UInt8], stampSec: Int32,
        stampNanosec: UInt32
    ) throws {}
    func updateGoalState(
        _ server: any RclActionServerHandle, goalId: [UInt8], event: RclGoalEvent
    ) throws {}
    func notifyGoalDone(_ server: any RclActionServerHandle) throws {}
    func destroyActionServer(_ server: any RclActionServerHandle) {}

    func createActionClient(
        node: any RclNodeHandle, actionTypeName: String, actionName: String, qos: TransportQoS,
        callbacks: RclActionClientCallbacks
    ) throws -> any RclActionClientHandle {
        SeamActionClient()
    }
    func sendGoalRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 { 1 }
    func sendCancelRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 { 1 }
    func sendResultRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 { 1 }
    func actionServerAvailable(_ client: any RclActionClientHandle) -> Bool { true }
    func destroyActionClient(_ client: any RclActionClientHandle) {}
}
