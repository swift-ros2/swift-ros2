import SwiftROS2Messages
import XCTest

@testable import SwiftROS2

/// Serves the six rcl_interfaces parameter services through the real rcl +
/// rmw_cyclonedds_cpp stack with DEFAULT `ROS2NodeOptions` (parameters
/// verification: the stock createNode path registers the services and the
/// /parameter_events publisher; the host lists / gets / sets).
/// Gated: requires the RCL backend built (SWIFT_ROS2_RCL) and a reachable
/// Jazzy host (LINUX_IP). This is a runbook test — CI never runs it. Start
/// the test, then within 60 s run on the host:
///
///   ros2 param list /swift_ros2_rcl/swift_ros2_rcl_param_test
///   ros2 param get /swift_ros2_rcl/swift_ros2_rcl_param_test answer
///   ros2 param set /swift_ros2_rcl/swift_ros2_rcl_param_test answer 42
///
/// `list` must show "answer", `get` must print "Integer value is: 41", and
/// `set` must print "Set parameter successful" — after which this test
/// observes the new value in the local store. If no set arrives within 60 s
/// the test skips (the host side is manual), unless RCL_SVC_EXPECT_CALL=1 is
/// set — in which case the absence of a set is a failure.
final class RclParameterIntegrationTests: XCTestCase {
    func testServeParametersOverRcl() async throws {
        #if !SWIFT_ROS2_RCL
            throw XCTSkip("RCL backend not built (set SWIFT_ROS2_ENABLE_RCL=1)")
        #else
            guard ProcessInfo.processInfo.environment["LINUX_IP"] != nil else {
                throw XCTSkip("LINUX_IP not set — skipping LAN integration test")
            }
            let expectCall = ProcessInfo.processInfo.environment["RCL_SVC_EXPECT_CALL"] == "1"

            let ctx = try await ROS2Context(transport: .rcl(domainId: 0))
            // Default options on purpose — this is the verification that the
            // stock createNode path (six parameter services + the
            // /parameter_events emitter) works on `.rcl` against a real host.
            let node = try await ctx.createNode(
                name: "swift_ros2_rcl_param_test", namespace: "/swift_ros2_rcl")
            let declared = try await node.declareParameter("answer", default: Int64(41))
            XCTAssertEqual(declared, 41)

            // Wait up to 60 s for the operator to issue the documented set.
            // `ros2 param list/get` exercise the services too, but only the
            // set is observable from this side, so it is the gate.
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            var observed: Int64 = 41
            while ContinuousClock.now < deadline {
                let p = try await node.getParameter("answer")
                if case .integer(let v) = p.value, v != 41 {
                    observed = v
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }

            guard observed != 41 else {
                await ctx.shutdown()
                if expectCall {
                    return XCTFail(
                        "no parameter set within 60 s with RCL_SVC_EXPECT_CALL=1 — "
                            + "did the host run the runbook? (see the header of this file)")
                }
                throw XCTSkip(
                    "no parameter set within 60 s — run the host-side commands documented "
                        + "in the header of this file to exercise this test")
            }

            // The documented host command sets 42; the host-side outputs of
            // `param list` / `param get` are the live assertions that the
            // Get/List services answered a real rclpy parameter client.
            XCTAssertEqual(observed, 42)

            await ctx.shutdown()
        #endif
    }
}
