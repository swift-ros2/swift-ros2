// EntityManager.swift
// Per-context entity ID counter for ROS 2 discovery

import Foundation

/// Generates unique entity IDs for ROS 2 nodes and publishers
///
/// Each context has its own entity manager. IDs are used in liveliness
/// tokens for ROS 2 discovery (makes topics visible in `ros2 topic list`).
package final class EntityManager: @unchecked Sendable {
    private var nextId: Int = 0
    private let lock = NSLock()

    package init() {}

    /// Get the next unique entity ID
    package func getNextEntityId() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }
}
