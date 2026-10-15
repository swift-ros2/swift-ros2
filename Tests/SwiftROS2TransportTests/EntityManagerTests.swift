import SwiftROS2Transport
import XCTest

final class EntityManagerTests: XCTestCase {
    func testIDsStartAtZeroAndIncrement() {
        let manager = EntityManager()
        XCTAssertEqual(manager.getNextEntityId(), 0)
        XCTAssertEqual(manager.getNextEntityId(), 1)
        XCTAssertEqual(manager.getNextEntityId(), 2)
    }

    func testInstancesAreIndependent() {
        let a = EntityManager()
        let b = EntityManager()
        _ = a.getNextEntityId()
        _ = a.getNextEntityId()
        _ = a.getNextEntityId()
        XCTAssertEqual(b.getNextEntityId(), 0, "Each EntityManager has its own counter")
    }

    func testConcurrentAllocationProducesDistinctIDs() {
        let manager = EntityManager()
        let iterations = 1_000
        let lock = NSLock()
        var ids: [Int] = []

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let id = manager.getNextEntityId()
            lock.lock()
            ids.append(id)
            lock.unlock()
        }

        XCTAssertEqual(ids.count, iterations)
        XCTAssertEqual(Set(ids).count, iterations, "All concurrently-allocated IDs must be unique")
    }
}
