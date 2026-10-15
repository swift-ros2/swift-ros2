#if SWIFT_ROS2_RCL && os(Linux)
    import Foundation
    import SwiftROS2RCL
    import XCTest

    /// On Linux the rmw is process-global and chosen by RMW_IMPLEMENTATION.
    /// RclClient sets it from the transport type before rcl_init and restores it.
    final class RclLinuxRmwEnvTests: XCTestCase {
        func testZenohSelectsRmwZenohAndRestores() {
            let outer = getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }
            defer {
                if let p = outer { setenv("RMW_IMPLEMENTATION", p, 1) } else { unsetenv("RMW_IMPLEMENTATION") }
            }
            unsetenv("RMW_IMPLEMENTATION")
            let c = RclClient()
            c.applyRmwImplementationEnv(zenoh: true)
            XCTAssertEqual(getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }, "rmw_zenoh_cpp")
            c.restoreRmwImplementationEnv()
            XCTAssertNil(getenv("RMW_IMPLEMENTATION").map { String(cString: $0) })
        }

        func testDdsSelectsRmwCyclonedds() {
            let outer = getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }
            defer {
                if let p = outer { setenv("RMW_IMPLEMENTATION", p, 1) } else { unsetenv("RMW_IMPLEMENTATION") }
            }
            unsetenv("RMW_IMPLEMENTATION")
            let c = RclClient()
            c.applyRmwImplementationEnv(zenoh: false)
            XCTAssertEqual(getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }, "rmw_cyclonedds_cpp")
            c.restoreRmwImplementationEnv()
            XCTAssertNil(
                getenv("RMW_IMPLEMENTATION").map { String(cString: $0) },
                "restore must unset RMW_IMPLEMENTATION when nothing was set before apply")
        }

        /// Two overlapping contexts (here on two RclClient instances) must, on the
        /// last teardown, restore RMW_IMPLEMENTATION to the value present BEFORE
        /// the first apply — never to an intermediate value a nested apply saw.
        func testOverlappingContextsRestoreToOriginalValue() {
            let outer = getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }
            defer {
                if let p = outer { setenv("RMW_IMPLEMENTATION", p, 1) } else { unsetenv("RMW_IMPLEMENTATION") }
            }
            setenv("RMW_IMPLEMENTATION", "rmw_original", 1)
            let a = RclClient()
            let b = RclClient()
            a.applyRmwImplementationEnv(zenoh: true)  // rmw_zenoh_cpp
            b.applyRmwImplementationEnv(zenoh: false)  // rmw_cyclonedds_cpp
            XCTAssertEqual(getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }, "rmw_cyclonedds_cpp")
            a.restoreRmwImplementationEnv()  // inner ref drops; slot must NOT be restored yet
            XCTAssertEqual(
                getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }, "rmw_cyclonedds_cpp",
                "a non-final restore must not touch the env slot")
            b.restoreRmwImplementationEnv()  // last ref drops; restore the original
            XCTAssertEqual(
                getenv("RMW_IMPLEMENTATION").map { String(cString: $0) }, "rmw_original",
                "the final restore must return the pre-apply value, not a nested one")
        }
    }
#endif
