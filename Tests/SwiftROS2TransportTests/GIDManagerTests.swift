import SwiftROS2Transport
import XCTest

final class GIDManagerTests: XCTestCase {
    func testGidIsExactlySixteenBytes() {
        let gid = GIDManager().getOrCreateGid()
        XCTAssertEqual(gid.count, GIDManager.gidSize)
        XCTAssertEqual(gid.count, 16)
    }

    func testGidIsStableAcrossCallsOnSameInstance() {
        let manager = GIDManager()
        let first = manager.getOrCreateGid()
        let second = manager.getOrCreateGid()
        XCTAssertEqual(first, second, "Same instance must return the same 16 bytes on every call")
    }

    func testDistinctInstancesProduceDistinctGids() {
        // Generate a small batch and verify they are all unique.
        // 128-bit randomness — birthday paradox at 2^64 trials, far beyond 100.
        var seen: Set<[UInt8]> = []
        for _ in 0..<100 {
            seen.insert(GIDManager().getOrCreateGid())
        }
        XCTAssertEqual(seen.count, 100, "Random GIDs collided unexpectedly")
    }
}
