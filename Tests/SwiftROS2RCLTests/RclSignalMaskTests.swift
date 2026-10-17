#if SWIFT_ROS2_RCL && !SWIFT_ROS2_RCL_RMW_ZENOH && !os(Windows)
    import Foundation
    import SwiftROS2RCL
    import XCTest

    /// Opening an RCL context and node leaves the signal masks of the calling
    /// thread and of the main thread as it found them (#290).
    ///
    /// CycloneDDS starts its threads with sigprocmask(), which on Apple platforms
    /// sets the mask of every thread in the process. An RCL context opened on a
    /// thread with SIGINT and SIGTERM blocked, as Dispatch worker threads have
    /// them, used to leave them blocked on the main thread, so Ctrl-C and kill no
    /// longer stopped the process.
    ///
    /// Domain 75 is used by no other test: rmw_cyclonedds_cpp starts CycloneDDS's
    /// threads only when it creates a domain, once per domain id and process.
    /// It must also differ from every wire DDS test domain (among them 71 to 74, 77
    /// and 80 in SwiftROS2DDSTests and 78 in the topic graph integration test):
    /// in the RCL graph the wire DDS bridge and rmw_cyclonedds_cpp share one
    /// CycloneDDS, and the macOS CI toolchain runs every test target in one
    /// process. A wire session creates its domain and never deletes it, so rmw's
    /// own dds_create_domain on that id fails with "Precondition Not Met".
    final class RclSignalMaskTests: XCTestCase {
        func testOpeningAContextOffTheMainThreadKeepsSignalMasks() throws {
            XCTAssertTrue(Thread.isMainThread)
            let mainBefore = Self.blockedSignals()

            var callerBefore: [Int32] = []
            var callerAfter: [Int32] = []
            var openError: Error?
            let done = DispatchSemaphore(value: 0)
            let caller = Thread {
                // Block what a Dispatch worker thread has blocked.
                var workerMask = sigset_t()
                sigemptyset(&workerMask)
                sigaddset(&workerMask, SIGINT)
                sigaddset(&workerMask, SIGTERM)
                pthread_sigmask(SIG_BLOCK, &workerMask, nil)
                callerBefore = Self.blockedSignals()
                let client = RclClient()
                do {
                    try client.createContext(
                        domainId: 75, transportType: .dds, unicastPeerAddresses: [],
                        networkInterface: nil, zenohRouterLocator: nil)
                    let node = try client.createNode(name: "signal_mask_test", namespace: "/")
                    client.destroyNode(node)
                } catch {
                    openError = error
                }
                client.destroyContext()
                callerAfter = Self.blockedSignals()
                done.signal()
            }
            caller.start()
            XCTAssertEqual(done.wait(timeout: .now() + 60), .success, "the context did not open and close in time")

            XCTAssertNil(openError)
            XCTAssertTrue(callerBefore.contains(SIGINT))
            XCTAssertEqual(callerAfter, callerBefore, "the calling thread's signal mask changed")
            XCTAssertEqual(Self.blockedSignals(), mainBefore, "the main thread's signal mask changed")
        }

        /// The signals blocked on the current thread.
        private static func blockedSignals() -> [Int32] {
            var mask = sigset_t()
            pthread_sigmask(SIG_BLOCK, nil, &mask)
            return (1..<32).filter { sigismember(&mask, $0) == 1 }
        }
    }
#endif
