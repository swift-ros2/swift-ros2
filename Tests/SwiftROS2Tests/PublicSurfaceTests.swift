import SwiftROS2
import XCTest

/// 2.0.0: the wire clients are an implementation detail. This file holds the
/// MIGRATION.md "1.x -> 2.0" connectivity-probe recipe — the replacement for a
/// 1.x `ZenohClient` open / close probe — written against the `SwiftROS2`
/// umbrella, imported without `@testable`.
///
/// What it proves: the recipe compiles against the umbrella. At runtime only
/// the failing-open path executes on wire graphs (nothing listens on the
/// locator, so `ROS2Context(transport:)` throws and the inspect / shutdown
/// lines are not reached there). What it cannot prove: that the umbrella API
/// stays `public`. `package` declarations are visible to every module of this
/// package, test targets included, so a demotion of umbrella API would still
/// compile here. The public-surface lock is the API-breakage gate
/// (`Scripts/diagnose-api-breaking-changes.sh` against the previous tag) plus
/// the release checklist's external consumer smoke. The gate catches removals
/// and signature changes, but SwiftPM's ABI digest also lists `package`
/// declarations, so a `public` -> `package` flip only shows up in the
/// external consumer smoke.
final class PublicSurfaceTests: XCTestCase {
    func testConnectivityProbeRecipeCompilesAndRuns() async {
        // Mirrors the MIGRATION "1.x -> 2.0" recipe. Nothing listens on this
        // port; on wire graphs the open throws and the test only checks that
        // the failure surfaces as an error rather than a crash.
        do {
            let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/127.0.0.1:1"))
            _ = ctx.isConnected
            _ = ctx.sessionId
            await ctx.shutdown()
        } catch {
            // expected: connection refused
        }
    }

    func testUmbrellaReexportsRosidl() throws {
        let encoder = CDREncoder()
        encoder.writeEncapsulationHeader()
        try Time(sec: 1, nanosec: 2).encode(to: encoder)
        XCTAssertFalse(ROS2Distro.jazzy.isLegacySchema)
        XCTAssertEqual(GoalStatusArray.typeInfo.typeName, "action_msgs/msg/GoalStatusArray")
        XCTAssertEqual(ParameterValue.typeInfo.typeName, "rcl_interfaces/msg/ParameterValue")
        XCTAssertEqual(UniqueIdentifierUUID().uuid.count, 16)
    }
}
