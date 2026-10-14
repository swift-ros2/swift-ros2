import SwiftROS2ExampleInterfaces
import SwiftROS2Messages
import XCTest

@testable import SwiftROS2

/// Serves example_interfaces/AddTwoInts through the real rcl +
/// rmw_cyclonedds_cpp stack and asserts a request from a real ROS 2 host was
/// answered correctly (plan task T6: macOS serves, the host calls).
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable
/// Jazzy host (LINUX_IP). This is a runbook test — CI never runs it. Start
/// the test, then within 60 s issue the call from the host:
///
///   ros2 service call /swift_ros2_rcl/add_two_ints \
///     example_interfaces/srv/AddTwoInts "{a: 2, b: 3}"
///
/// The host must print "sum: 5". If no request arrives within 60 s the test
/// skips (the host side is manual), unless RCL_SVC_EXPECT_CALL=1 is set — in
/// which case the absence of a request is a failure.
final class RclServiceIntegrationTests: XCTestCase {
    func testServeAddTwoIntsOverRcl() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip("LINUX_IP not set — skipping LAN integration test")
            }
            let expectCall = ProcessInfo.processInfo.environment["RCL_SVC_EXPECT_CALL"] == "1"

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_svc_test", namespace: "/swift_ros2_rcl")

            // Capture the requests the handler answered so the test can assert
            // both that a call arrived and what it computed.
            let received = ReceivedRequests()
            _ = try await node.createService(AddTwoIntsSrv.self, name: "add_two_ints") { request in
                received.record(request)
                return AddTwoIntsResponse(sum: request.a + request.b)
            }

            // Wait up to 60 s for the operator to issue the documented call.
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while ContinuousClock.now < deadline, received.snapshot.isEmpty {
                try await Task.sleep(for: .milliseconds(200))
            }

            let requests = received.snapshot
            guard let first = requests.first else {
                await ctx.shutdown()
                if expectCall {
                    return XCTFail(
                        "no AddTwoInts request within 60 s with RCL_SVC_EXPECT_CALL=1 — "
                            + "did the host run the call? (see the header of this file)")
                }
                throw XCTSkip(
                    "no AddTwoInts request within 60 s — run the host-side call documented "
                        + "in the header of this file to exercise this test")
            }

            // The documented host command sends {a: 2, b: 3}; the host-side
            // "sum: 5" output is the real assertion that the response decoded.
            XCTAssertEqual(first.a, 2)
            XCTAssertEqual(first.b, 3)

            await ctx.shutdown()
        #endif
    }
}

#if SWIFT_ROS2_RCL
    /// Lock-protected capture of handled requests — the service handler runs on
    /// a detached task, the test polls from the test executor.
    private final class ReceivedRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AddTwoIntsRequest] = []

        func record(_ request: AddTwoIntsRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var snapshot: [AddTwoIntsRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }
#endif
