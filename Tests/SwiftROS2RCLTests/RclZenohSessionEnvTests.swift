#if SWIFT_ROS2_RCL
    import Foundation
    import SwiftROS2RCL
    import SwiftROS2Transport
    import XCTest

    // MARK: - LocatorRecordingClient

    /// Minimal `RclClientProtocol` conformer that records the zenoh router locator
    /// passed to `createContext`. All other requirements are no-ops or fatal traps
    /// since the Task 5 test only exercises the `open` → `createContext` path.
    private final class LocatorRecordingClient: RclClientProtocol, @unchecked Sendable {
        var isAvailable: Bool { true }

        /// Wrapped in Optional so `.some(.none)` means "called with nil" and
        /// `.none` means "createContext was never called".
        private(set) var recordedZenohLocator: String??

        func createContext(
            domainId: Int32, transportType: TransportType, unicastPeerAddresses: [String],
            networkInterface: String?, zenohRouterLocator: String?
        ) throws {
            recordedZenohLocator = Optional(zenohRouterLocator)
        }

        func destroyContext() {}

        func createNode(name: String, namespace: String) throws -> any RclNodeHandle {
            fatalError("unused")
        }
        func destroyNode(_ node: any RclNodeHandle) {}

        func createPublisher(
            node: any RclNodeHandle, typeName: String, typeHash: String?, topic: String,
            qos: TransportQoS
        ) throws -> any RclPublisherHandle { fatalError("unused") }
        func publishSerialized(_ publisher: any RclPublisherHandle, data: Data) throws {
            fatalError("unused")
        }

        func createSubscription(
            node: any RclNodeHandle, typeName: String, typeHash: String?, topic: String,
            qos: TransportQoS, handler: @escaping @Sendable (Data, UInt64) -> Void
        ) throws -> any RclSubscriptionHandle { fatalError("unused") }
        func destroySubscription(_ subscription: any RclSubscriptionHandle) {}

        func createServiceServer(
            node: any RclNodeHandle, srvTypeName: String, serviceName: String, qos: TransportQoS,
            onRequest: @escaping @Sendable (Data, [UInt8]) -> Void
        ) throws -> any RclServiceHandle { fatalError("unused") }
        func sendResponse(_ service: any RclServiceHandle, requestId: [UInt8], data: Data) throws {
            fatalError("unused")
        }
        func destroyServiceServer(_ service: any RclServiceHandle) {}

        func createServiceClient(
            node: any RclNodeHandle, srvTypeName: String, serviceName: String, qos: TransportQoS,
            onResponse: @escaping @Sendable (Int64, Data) -> Void
        ) throws -> any RclClientHandle { fatalError("unused") }
        func sendRequest(_ client: any RclClientHandle, data: Data) throws -> Int64 {
            fatalError("unused")
        }
        func serverAvailable(_ client: any RclClientHandle) -> Bool { fatalError("unused") }
        func destroyServiceClient(_ client: any RclClientHandle) {}

        func createActionServer(
            node: any RclNodeHandle, actionTypeName: String, actionName: String, qos: TransportQoS,
            callbacks: RclActionServerCallbacks
        ) throws -> any RclActionServerHandle { fatalError("unused") }
        func sendGoalResponse(
            _ server: any RclActionServerHandle, requestId: [UInt8], data: Data
        ) throws { fatalError("unused") }
        func sendCancelResponse(
            _ server: any RclActionServerHandle, requestId: [UInt8], data: Data
        ) throws { fatalError("unused") }
        func sendResultResponse(
            _ server: any RclActionServerHandle, requestId: [UInt8], data: Data
        ) throws { fatalError("unused") }
        func publishActionFeedback(_ server: any RclActionServerHandle, data: Data) throws {
            fatalError("unused")
        }
        func publishActionStatus(_ server: any RclActionServerHandle) throws {
            fatalError("unused")
        }
        func acceptGoal(
            _ server: any RclActionServerHandle, goalId: [UInt8], stampSec: Int32,
            stampNanosec: UInt32
        ) throws { fatalError("unused") }
        func updateGoalState(
            _ server: any RclActionServerHandle, goalId: [UInt8], event: RclGoalEvent
        ) throws { fatalError("unused") }
        func notifyGoalDone(_ server: any RclActionServerHandle) throws { fatalError("unused") }
        func destroyActionServer(_ server: any RclActionServerHandle) {}

        func createActionClient(
            node: any RclNodeHandle, actionTypeName: String, actionName: String, qos: TransportQoS,
            callbacks: RclActionClientCallbacks
        ) throws -> any RclActionClientHandle { fatalError("unused") }
        func sendGoalRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
            fatalError("unused")
        }
        func sendCancelRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
            fatalError("unused")
        }
        func sendResultRequest(_ client: any RclActionClientHandle, data: Data) throws -> Int64 {
            fatalError("unused")
        }
        func actionServerAvailable(_ client: any RclActionClientHandle) -> Bool {
            fatalError("unused")
        }
        func destroyActionClient(_ client: any RclActionClientHandle) {}
    }

    // MARK: - RclZenohSessionEnvTests

    /// Router plumbing: the RCL-over-Zenoh path injects the router locator
    /// into rmw_zenoh_cpp via a generated session-config json5 pointed at by
    /// ZENOH_SESSION_CONFIG_URI — the Zenoh analog of the DDS CYCLONEDDS_URI
    /// plumbing in RclDiscoveryEnvTests. These tests are pure: no rmw, no router.
    final class RclZenohSessionEnvTests: XCTestCase {
        func testSessionConfigCarriesConnectEndpointInClientMode() {
            let cfg = RclClient().makeZenohSessionConfigJSON5(locator: "tcp/192.168.1.85:7447")
            XCTAssertTrue(cfg.contains("\"tcp/192.168.1.85:7447\""), "connect endpoint missing")
            XCTAssertTrue(cfg.contains("mode: \"client\""), "client mode missing")
            XCTAssertTrue(cfg.contains("connect"), "connect block missing")
            XCTAssertTrue(cfg.contains("enabled: false"), "multicast scouting must be disabled")
            // rmw_zenoh_cpp builds every publisher as an AdvancedPublisher with
            // Sequencing::Timestamp; zenoh-c aborts publisher creation unless the
            // (wholesale-replacing) session config enables client timestamping.
            XCTAssertTrue(cfg.contains("timestamping"), "timestamping block missing")
            XCTAssertTrue(cfg.contains("client: true"), "client timestamping must be enabled")
        }

        func testApplyZenohSessionEnvExportsAndRestores() {
            // Hermetic: snapshot + restore whatever the environment already had.
            let outerURI = getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) }
            let outerAtt = getenv("ZENOH_ROUTER_CHECK_ATTEMPTS").map { String(cString: $0) }
            defer {
                if let p = outerURI {
                    setenv("ZENOH_SESSION_CONFIG_URI", p, 1)
                } else {
                    unsetenv("ZENOH_SESSION_CONFIG_URI")
                }
                if let p = outerAtt {
                    setenv("ZENOH_ROUTER_CHECK_ATTEMPTS", p, 1)
                } else {
                    unsetenv("ZENOH_ROUTER_CHECK_ATTEMPTS")
                }
            }
            unsetenv("ZENOH_SESSION_CONFIG_URI")  // known-clear starting point
            unsetenv("ZENOH_ROUTER_CHECK_ATTEMPTS")

            let client = RclClient()
            XCTAssertTrue(client.applyZenohSessionEnv(locator: "tcp/192.168.1.85:7447"))
            let uri = getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) }
            XCTAssertNotNil(uri)
            let contents = (try? String(contentsOfFile: uri!, encoding: .utf8)) ?? ""
            XCTAssertTrue(contents.contains("tcp/192.168.1.85:7447"))
            XCTAssertEqual(
                getenv("ZENOH_ROUTER_CHECK_ATTEMPTS").map { String(cString: $0) }, "1",
                "router check attempts must be pinned to 1 (non-blocking)")

            client.restoreZenohSessionEnv()
            XCTAssertNil(getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) })
            XCTAssertNil(getenv("ZENOH_ROUTER_CHECK_ATTEMPTS").map { String(cString: $0) })
            XCTAssertFalse(FileManager.default.fileExists(atPath: uri!), "temp config not cleaned up")
        }

        func testRestoreZenohSessionEnvIsNoOpWhenNothingApplied() {
            // Calling restore on a fresh client must not crash or mutate the env.
            let outerURI = getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) }
            RclClient().restoreZenohSessionEnv()
            XCTAssertEqual(getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) }, outerURI)
        }

        func testOpenForwardsZenohLocatorToCreateContext() async throws {
            let client = LocatorRecordingClient()
            let session = RclTransportSession(client: client)
            try await session.open(config: .zenoh(locator: "tcp/10.0.0.2:7447"))
            XCTAssertEqual(client.recordedZenohLocator, .some("tcp/10.0.0.2:7447"))
        }

        func testEmbeddableZenohLocatorRule() {
            // Legitimate endpoints (incl. IPv6 + a `#`-metadata tail) embed cleanly.
            XCTAssertTrue(RclClient.isEmbeddableZenohLocator("tcp/192.168.1.85:7447"))
            XCTAssertTrue(RclClient.isEmbeddableZenohLocator("tcp/[::1]:7447#iface=en0"))
            // json5-string-breaking characters must be rejected, not escaped.
            XCTAssertFalse(RclClient.isEmbeddableZenohLocator("tcp/h:7447\"]}"), "quote rejected")
            XCTAssertFalse(RclClient.isEmbeddableZenohLocator("tcp/h:7447\\"), "backslash rejected")
            XCTAssertFalse(RclClient.isEmbeddableZenohLocator("tcp/h:7447\n"), "newline rejected")
        }

        func testCreateContextRejectsUninjectableLocatorWithoutSettingEnv() {
            // A locator that would corrupt the json5 must fail loudly at
            // createContext — before any rcl call — rather than silently fall back
            // to default (router-less, multicast) settings. The validation throws
            // ahead of crcl_context_create, so this needs no live rmw.
            let before = getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) }
            XCTAssertThrowsError(
                try RclClient().createContext(
                    domainId: 0, transportType: .zenoh, unicastPeerAddresses: [],
                    networkInterface: nil, zenohRouterLocator: "tcp/host:7447\"]}injected")
            ) { error in
                guard case TransportError.invalidConfiguration = error else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
            }
            XCTAssertEqual(
                getenv("ZENOH_SESSION_CONFIG_URI").map { String(cString: $0) }, before,
                "a rejected locator must not touch the Zenoh session env")
        }
    }
#endif
