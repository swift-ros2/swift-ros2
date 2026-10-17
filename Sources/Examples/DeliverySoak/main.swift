// delivery-soak — memory check for subscription delivery (the `memory-soak` workflow).
//
// Publishes a 1280x720 rgb8 `sensor_msgs/Image` at 30 Hz to a subscription in the same process,
// whose handler sleeps 100 ms, so the subscriber is three times slower than the publisher. After a
// warm-up it samples the process footprint (`phys_footprint` on Darwin, `VmRSS` on Linux), runs
// for the measured duration, samples again and prints the delta. With `latest` delivery the delta
// should stay small (one waiting payload, one message being handled); `stream` is recorded for
// comparison.
//
// Usage:
//   delivery-soak <zenoh|dds> <latest|stream> [--locator STR] [--domain N] [--warmup-s N]
//                 [--duration-s N] [--rate-hz N] [--handler-ms N] [--width N] [--height N]
//                 [--best-effort]
//
// The zenoh transport needs a router at `--locator` (default tcp/127.0.0.1:7447) and uses two
// contexts, because zenoh-pico does not route a session's own puts to its own subscribers. The
// dds transport runs on the loopback interface with multicast discovery on `--domain` (default
// 76). Output: `delivery_soak SAMPLE ...` lines, then one `delivery_soak RESULT ...` line.

import Foundation
import SwiftROS2
import SwiftROS2TestFixtures

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - CLI

let args = CommandLine.arguments

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func intOption(_ name: String, _ fallback: Int) -> Int {
    option(name).flatMap(Int.init) ?? fallback
}

guard args.count >= 3, ["zenoh", "dds"].contains(args[1]), ["latest", "stream"].contains(args[2]) else {
    print(
        "usage: delivery-soak <zenoh|dds> <latest|stream> [--locator STR] [--domain N] [--warmup-s N] "
            + "[--duration-s N] [--rate-hz N] [--handler-ms N] [--width N] [--height N] [--best-effort]")
    exit(2)
}

let transportName = args[1]
let delivery: SubscriptionDelivery = args[2] == "latest" ? .latestOnly : .stream
let locator = option("--locator") ?? "tcp/127.0.0.1:7447"
let domain = intOption("--domain", 76)
let warmupS = intOption("--warmup-s", 15)
let durationS = intOption("--duration-s", 60)
let rateHz = max(1, intOption("--rate-hz", 30))
let handlerMs = intOption("--handler-ms", 100)
let qos: QoSProfile =
    args.contains("--best-effort")
    ? .sensorData
    : QoSProfile(reliability: .reliable, durability: .volatile, history: .keepLast(10))

// MARK: - Memory

/// The memory the process uses, in bytes: `phys_footprint` on Darwin (what Xcode and jetsam
/// count), `VmRSS` on Linux. Zero when it cannot be read.
func footprintBytes() -> UInt64 {
    #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    #else
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return 0 }
        for line in status.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            let kilobytes = line.split(separator: " ").compactMap { UInt64($0) }.first ?? 0
            return kilobytes * 1024
        }
        return 0
    #endif
}

func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / 1_048_576)
}

// MARK: - Counters

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Run

let config: TransportConfig =
    transportName == "zenoh"
    ? .zenoh(locator: locator, domainId: domain)
    : .ddsMulticast(domainId: domain)

let subContext = try await ROS2Context(transport: config, domainId: domain)
let pubContext = try await ROS2Context(transport: config, domainId: domain)
let subNode = try await subContext.createNode(name: "soak_sub", namespace: "/delivery_soak")
let pubNode = try await pubContext.createNode(name: "soak_pub", namespace: "/delivery_soak")

let delivered = Counter()
let handlerSleep = TimeInterval(max(0, handlerMs)) / 1000
let subscription = try await subNode.createSubscription(
    Image.self, topic: "image", qos: qos, delivery: delivery
) { _ in
    delivered.increment()
    Thread.sleep(forTimeInterval: handlerSleep)
}
let publisher = try await pubNode.createPublisher(Image.self, topic: "image", qos: qos)

let width = UInt32(max(1, intOption("--width", 1280)))
let height = UInt32(max(1, intOption("--height", 720)))
let image = Image(
    header: Header(frameId: "soak_camera"),
    height: height, width: width, encoding: "rgb8", step: width * 3,
    data: [UInt8](repeating: 0x5A, count: Int(width * height * 3)))

let published = Counter()
let publishFailures = Counter()
let periodNs = UInt64(1_000_000_000 / rateHz)
let publishTask = Task.detached {
    var next = DispatchTime.now().uptimeNanoseconds
    while !Task.isCancelled {
        do {
            try publisher.publish(image)
            published.increment()
        } catch {
            publishFailures.increment()
        }
        next += periodNs
        let now = DispatchTime.now().uptimeNanoseconds
        if next > now { try? await Task.sleep(nanoseconds: next - now) } else { next = now }
    }
}

func sample(_ label: String, elapsedS: Int) -> UInt64 {
    let bytes = footprintBytes()
    print(
        "delivery_soak SAMPLE phase=\(label) t=\(elapsedS)s footprint_mb=\(megabytes(bytes)) "
            + "published=\(published.current) delivered=\(delivered.current)")
    return bytes
}

print(
    "delivery_soak START transport=\(transportName) delivery=\(args[2]) rate_hz=\(rateHz) "
        + "handler_ms=\(handlerMs) warmup_s=\(warmupS) duration_s=\(durationS) "
        + "payload_mb=\(megabytes(UInt64(image.data.count)))")

for t in 0..<warmupS {
    if t % 5 == 0 { _ = sample("warmup", elapsedS: t) }
    try await Task.sleep(nanoseconds: 1_000_000_000)
}
let start = sample("start", elapsedS: 0)
let deliveredAtStart = delivered.current
for t in 1...max(1, durationS) {
    try await Task.sleep(nanoseconds: 1_000_000_000)
    if t % 10 == 0 { _ = sample("run", elapsedS: t) }
}
let end = sample("end", elapsedS: durationS)

publishTask.cancel()
subscription.cancel()
await pubContext.shutdown()
await subContext.shutdown()

let delta = Int64(bitPattern: end &- start)
print(
    "delivery_soak RESULT transport=\(transportName) delivery=\(args[2]) "
        + "start_mb=\(megabytes(start)) end_mb=\(megabytes(end)) "
        + "delta_mb=\(String(format: "%.1f", Double(delta) / 1_048_576)) "
        + "published=\(published.current) publish_failures=\(publishFailures.current) "
        + "delivered_in_run=\(delivered.current - deliveredAtStart)")
