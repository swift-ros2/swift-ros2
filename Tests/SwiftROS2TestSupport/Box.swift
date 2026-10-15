import Foundation

/// Sendable container for capturing values from `@Sendable` handlers in tests.
///
/// Transport and subscription APIs hand the user a `@Sendable` closure; asserting on what the handler
/// observed requires a shared container that is safe to touch from any concurrency context. `Box`
/// wraps one value behind an `NSLock`.
public final class Box<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    public init(_ value: T) {
        self._value = value
    }

    public var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }

    /// Mutates the value in place under the lock, for example `box.mutate { $0.append(x) }`.
    public func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&_value)
    }
}

extension Box where T: RangeReplaceableCollection {
    /// Appends an element under the lock.
    public func append(_ element: T.Element) {
        mutate { $0.append(element) }
    }
}
