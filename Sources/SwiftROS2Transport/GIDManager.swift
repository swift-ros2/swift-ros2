// GIDManager.swift
// Publisher GID (Global Identifier) management

import Foundation

/// Manages a stable 16-byte publisher GID
///
/// The GID uniquely identifies a publisher and must be stable across
/// publish calls within a session.
package final class GIDManager: @unchecked Sendable {
    package static let gidSize = 16

    /// A fresh random 16-byte GID.
    package static func randomGid() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<gidSize).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private var cachedGid: [UInt8]?
    private let lock = NSLock()

    package init() {}

    /// Get or create a 16-byte publisher GID
    package func getOrCreateGid() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        if let gid = cachedGid {
            return gid
        }

        let gid = Self.randomGid()
        cachedGid = gid
        return gid
    }
}
