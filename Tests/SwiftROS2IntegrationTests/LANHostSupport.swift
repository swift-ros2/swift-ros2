import SwiftROS2
import XCTest

extension XCTestCase {
    /// Waits until `publisher` reports a matched subscription, which on the LAN tests is the
    /// subscriber the person running the test started on the host. Polls instead of sleeping a
    /// fixed time, and fails the test when no subscriber showed up.
    ///
    /// A transport that cannot tell reports a match right away (see
    /// ``ROS2Publisher/hasMatchedSubscriptions``), so the check is only as strong as the transport's
    /// own matching status.
    func assertHostSubscriberMatches<M>(
        _ publisher: ROS2Publisher<M>,
        within timeout: Duration = .seconds(30),
        hint: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !publisher.hasMatchedSubscriptions {
            if ContinuousClock.now >= deadline {
                XCTFail("no subscription matched within \(timeout) — \(hint)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
