// DecodeFailureReporter.swift
// Counts and logs the messages a subscription could not decode.

import Foundation

#if canImport(os)
    import os
#endif

/// Counts the messages one subscription failed to decode and logs them, rate-limited.
///
/// A message that does not decode is dropped, which looks the same as no data. The first
/// failure is logged right away; after that at most one line is logged per `interval`,
/// carrying the number of failures it stands for. The counter always counts every failure.
final class DecodeFailureReporter: @unchecked Sendable {
    /// The shortest time between two log lines of one subscription.
    static let defaultInterval: TimeInterval = 10

    private let topic: String
    private let typeName: String
    private let intervalNs: UInt64
    private let now: @Sendable () -> UInt64
    private let emit: @Sendable (String) -> Void

    private let lock = NSLock()
    private var total = 0
    private var unreported = 0
    private var lastReportNs: UInt64?

    /// - Parameters:
    ///   - topic: The fully qualified topic, named in each log line.
    ///   - typeName: The ROS 2 type name the subscription decodes, named in each log line.
    ///   - interval: The shortest time between two log lines.
    ///   - now: A monotonic clock in nanoseconds; tests inject their own.
    ///   - emit: Receives each log line; defaults to the system log.
    init(
        topic: String,
        typeName: String,
        interval: TimeInterval = DecodeFailureReporter.defaultInterval,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        emit: @escaping @Sendable (String) -> Void = DecodeFailureReporter.logToSystem
    ) {
        self.topic = topic
        self.typeName = typeName
        self.intervalNs = UInt64(max(0, interval) * 1_000_000_000)
        self.now = now
        self.emit = emit
    }

    /// The number of messages that failed to decode, including the ones not logged.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    /// Record one decode failure and log it unless one was logged less than `interval` ago.
    func record(_ error: Error) {
        let time = now()
        lock.lock()
        total += 1
        unreported += 1
        let due = lastReportNs.map { time &- $0 >= intervalNs } ?? true
        let failures = unreported
        let totalSoFar = total
        if due {
            lastReportNs = time
            unreported = 0
        }
        lock.unlock()

        guard due else { return }
        var line = "Dropped a message on \(topic) (\(typeName)) that failed to decode: \(error)"
        if failures > 1 {
            line += " (\(failures) failures since the last report, \(totalSoFar) in total)"
        }
        emit(line)
    }

    /// The default sink: the unified log on Apple platforms, standard error elsewhere.
    static let logToSystem: @Sendable (String) -> Void = { line in
        #if canImport(os)
            subscriptionLogger.error("\(line, privacy: .public)")
        #else
            FileHandle.standardError.write(Data("swift-ros2: \(line)\n".utf8))
        #endif
    }
}

#if canImport(os)
    private let subscriptionLogger = Logger(subsystem: "com.youtalk.swift-ros2", category: "Subscription")
#endif
