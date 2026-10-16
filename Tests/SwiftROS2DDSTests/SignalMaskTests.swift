#if !os(Windows)
    import Foundation
    import XCTest

    @testable import SwiftROS2DDS
    @testable import SwiftROS2Transport

    /// Opening a wire DDS session leaves the signal masks of the calling thread
    /// and of the main thread as it found them (#290).
    ///
    /// CycloneDDS starts its threads with sigprocmask(), which on Apple platforms
    /// sets the mask of every thread in the process. A session opened on a
    /// thread with SIGINT and SIGTERM blocked, as Dispatch worker threads have
    /// them, used to leave them blocked on the main thread, so Ctrl-C and kill no
    /// longer stopped the process.
    ///
    /// Domain 73 is used by no other test: the bridge starts CycloneDDS's threads
    /// only when it creates a domain, once per domain id and process.
    final class SignalMaskTests: XCTestCase {
        func testOpeningASessionOffTheMainThreadKeepsSignalMasks() throws {
            XCTAssertTrue(Thread.isMainThread)
            let mainBefore = Self.blockedSignals()

            var callerBefore: [Int32] = []
            var callerAfter: [Int32] = []
            var sessionError: Error?
            let done = DispatchSemaphore(value: 0)
            let caller = Thread {
                // Block what a Dispatch worker thread has blocked.
                var workerMask = sigset_t()
                sigemptyset(&workerMask)
                sigaddset(&workerMask, SIGINT)
                sigaddset(&workerMask, SIGTERM)
                pthread_sigmask(SIG_BLOCK, &workerMask, nil)
                callerBefore = Self.blockedSignals()
                do {
                    let client = DDSClient()
                    try client.createSession(domainId: 73, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
                    try client.destroySession()
                } catch {
                    sessionError = error
                }
                callerAfter = Self.blockedSignals()
                done.signal()
            }
            caller.start()
            XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "the session did not open and close in time")

            XCTAssertNil(sessionError)
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
