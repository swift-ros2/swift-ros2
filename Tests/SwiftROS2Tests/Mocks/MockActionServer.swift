// MockActionServer.swift
// In-memory TransportActionServer for SwiftROS2 umbrella unit tests.
//
// Conforms to PublishesActionFeedback so the umbrella can publish feedback
// and status snapshots without needing a real DDS / Zenoh transport.

import Foundation
import SwiftROS2Transport

final class MockActionServer: TransportActionServer, PublishesActionFeedback, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var closed = false

    private var _publishedFeedbacks: [(goalId: [UInt8], cdr: Data)] = []
    private var _publishedStatuses: [[ActionStatusEntry]] = []

    init(name: String = "/mock_action") {
        self.name = name
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        closed = true
    }

    func publishFeedback(goalId: [UInt8], feedbackCDR: Data) throws {
        lock.lock()
        _publishedFeedbacks.append((goalId, feedbackCDR))
        lock.unlock()
    }

    func publishStatus(entries: [ActionStatusEntry]) throws {
        lock.lock()
        _publishedStatuses.append(entries)
        lock.unlock()
    }

    var publishedFeedbacks: [(goalId: [UInt8], cdr: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return _publishedFeedbacks
    }

    var publishedStatuses: [[ActionStatusEntry]] {
        lock.lock()
        defer { lock.unlock() }
        return _publishedStatuses
    }
}
