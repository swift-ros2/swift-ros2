// rcl-bench — rcl serialized publish (.rcl backend) vs pure-Swift wire-DDS (.dds)
// vs Zenoh (.zenoh) benchmark. One backend per process so the
// two DDS stacks never share a participant. The `zenoh` backend resolves to
// the zenoh-pico wire path on the default build and to rcl + rmw_zenoh_cpp on
// the SWIFT_ROS2_RCL_RMW=zenoh variant; its router locator comes from
// `--locator`, then SWIFT_ROS2_ZENOH_LOCATOR, then tcp/127.0.0.1:7447.
//
// Usage:
//   rcl-bench <rcl|dds|zenoh> <publish|roundtrip|roundtrip-lan|encode> [imu|image64k|cloud120k]
//             [--count N] [--rate-hz N] [--domain N] [--locator STR]
//
// Modes:
//   publish       — per-publish call latency + max-rate throughput (no subscriber)
//   roundtrip     — in-process pub -> sub end-to-end latency via header.stamp
//                   (send time embedded; receiver computes now - stamp on the
//                   delivery callback thread)
//   roundtrip-lan — end-to-end latency vs a LAN host that relays `bench` ->
//                   `bench_echo` (run `ros2 run topic_tools relay <ns>/bench
//                   <ns>/bench_echo` on the host)
//   encode        — serialization only: the pure-Swift CDREncoder, which every
//                   backend (rcl included) uses to encode before publishing
//
// Results print as single `rcl_bench RESULT ...` key=value lines (µs).

import Foundation
import SwiftROS2
import SwiftROS2Bench
import SwiftROS2RCL
import SwiftROS2TestFixtures

// MARK: - CLI

let args = CommandLine.arguments
guard args.count >= 3 else {
    print(
        """
        usage: rcl-bench <rcl|dds|zenoh> <publish|roundtrip|roundtrip-lan|encode> \
        [imu|image64k|cloud120k] [--count N] [--rate-hz N] [--domain N] [--locator STR]
        """)
    exit(2)
}
let backend = args[1]
let mode = args[2]
let payload = args.count > 3 && !args[3].hasPrefix("--") ? args[3] : "imu"
guard HarnessCLI.supportedBackends.contains(backend),
    ["publish", "roundtrip", "roundtrip-lan", "encode"].contains(mode),
    ["imu", "image64k", "cloud120k"].contains(payload)
else {
    print("rcl_bench FAIL: unknown backend/mode/payload \(backend)/\(mode)/\(payload)")
    exit(2)
}

func intOption(_ name: String, default def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1])
    else { return def }
    return v
}

// Defaults scale with payload size so large-payload runs stay short.
let isLarge = payload != "imu"
let count = intOption(
    "--count", default: mode == "encode" ? (isLarge ? 5_000 : 100_000) : (isLarge ? 1_000 : 10_000))
let rateHz = intOption("--rate-hz", default: 0)  // 0 = max rate
let warmup = isLarge ? 100 : 1_000
let domainId = intOption("--domain", default: 42)
let zenohLocator = HarnessCLI.resolveZenohLocator(
    arguments: args, environment: ProcessInfo.processInfo.environment)

// MARK: - timing helpers

@inline(__always) func nowNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func percentiles(_ samplesNS: [UInt64]) -> (p50: Double, p95: Double, p99: Double, max: Double) {
    let s = samplesNS.sorted()
    guard !s.isEmpty else { return (0, 0, 0, 0) }
    func pct(_ p: Double) -> Double {
        Double(s[min(s.count - 1, Int(Double(s.count) * p))]) / 1_000.0
    }
    return (pct(0.50), pct(0.95), pct(0.99), Double(s[s.count - 1]) / 1_000.0)
}

func printResult(_ fields: [String: String]) {
    let ordered = [
        "backend", "stack", "mode", "payload", "count", "received", "rate_hz", "msgs_per_s",
        "p50us", "p95us", "p99us", "maxus", "wall_s", "bytes",
    ]
    let kv = ordered.compactMap { k in fields[k].map { "\(k)=\($0)" } }
    print("rcl_bench RESULT " + kv.joined(separator: " "))
    fflush(stdout)
}

// MARK: - payloads (deterministic, finite)

func makeImu() -> Imu {
    Imu(
        header: Header(stamp: Time(sec: 0, nanosec: 0), frameId: "bench"),
        orientation: Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.4),
        orientationCovariance: [0, 1, 2, 3, 4, 5, 6, 7, 8],
        angularVelocity: Vector3(x: 1.5, y: 2.5, z: 3.5),
        angularVelocityCovariance: [9, 10, 11, 12, 13, 14, 15, 16, 17],
        linearAcceleration: Vector3(x: 9.8, y: 0.0, z: -9.8),
        linearAccelerationCovariance: [18, 19, 20, 21, 22, 23, 24, 25, 26])
}

func makeImage64k() -> CompressedImage {
    CompressedImage(
        header: Header(stamp: Time(sec: 0, nanosec: 0), frameId: "bench"),
        format: "jpeg",
        data: (0..<65_536).map { UInt8($0 & 0xFF) })
}

func makeCloud120k() -> PointCloud2 {
    PointCloud2(
        header: Header(stamp: Time(sec: 0, nanosec: 0), frameId: "bench"),
        height: 1, width: 10_000,
        fields: [
            PointField(name: "x", offset: 0, datatype: 7, count: 1),
            PointField(name: "y", offset: 4, datatype: 7, count: 1),
            PointField(name: "z", offset: 8, datatype: 7, count: 1),
        ],
        isBigendian: false, pointStep: 12, rowStep: 120_000,
        data: (0..<120_000).map { UInt8($0 & 0xFF) }, isDense: true)
}

@inline(__always) func stampNow(_ t: inout Time) {
    let ns = nowNS()
    t = Time(sec: Int32(ns / 1_000_000_000), nanosec: UInt32(ns % 1_000_000_000))
}

@inline(__always) func stampedNS(_ t: Time) -> UInt64 {
    UInt64(t.sec) * 1_000_000_000 + UInt64(t.nanosec)
}

// MARK: - receive collector (delivery-thread safe)

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [UInt64] = []
    init(capacity: Int) { samples.reserveCapacity(capacity) }
    func record(_ latencyNS: UInt64) {
        lock.lock()
        samples.append(latencyNS)
        lock.unlock()
    }
    var snapshot: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

// MARK: - encode mode (no context needed)

func wireEncodedBytes<M: CDREncodable>(_ msg: M) throws -> Int {
    let enc = CDREncoder(isLegacySchema: false)
    enc.writeEncapsulationHeader()
    try msg.encode(to: enc)
    return enc.getData().count
}

func runEncode() throws {
    var samples: [UInt64] = []
    samples.reserveCapacity(count)
    var bytes = 0
    let start = nowNS()
    // Every backend encodes with the same pure-Swift CDREncoder (the rcl
    // backend publishes the encoded bytes through rcl_publish_serialized_message),
    // so the encode seam is identical for each backend token.
    switch payload {
    case "imu":
        let m = makeImu()
        for _ in 0..<count {
            let t0 = nowNS()
            bytes = try wireEncodedBytes(m)
            samples.append(nowNS() - t0)
        }
    case "image64k":
        let m = makeImage64k()
        for _ in 0..<count {
            let t0 = nowNS()
            bytes = try wireEncodedBytes(m)
            samples.append(nowNS() - t0)
        }
    case "cloud120k":
        let m = makeCloud120k()
        for _ in 0..<count {
            let t0 = nowNS()
            bytes = try wireEncodedBytes(m)
            samples.append(nowNS() - t0)
        }
    default: fatalError("unreachable")
    }
    let wall = Double(nowNS() - start) / 1e9
    let p = percentiles(samples)
    printResult([
        "backend": backend, "stack": HarnessCLI.stack(forBackend: backend),
        "mode": mode, "payload": payload, "count": "\(count)",
        "msgs_per_s": String(format: "%.0f", Double(count) / wall),
        "p50us": String(format: "%.2f", p.p50), "p95us": String(format: "%.2f", p.p95),
        "p99us": String(format: "%.2f", p.p99), "maxus": String(format: "%.2f", p.max),
        "wall_s": String(format: "%.3f", wall), "bytes": "\(bytes)",
    ])
}

// MARK: - publish / roundtrip modes

func transportConfig() -> TransportConfig {
    switch backend {
    case "rcl": return .rcl(domainId: domainId)
    case "zenoh": return .zenoh(locator: zenohLocator, domainId: domainId)
    default: return .ddsMulticast(domainId: domainId)
    }
}

func runPubSub() async throws {
    let qos = QoSProfile(
        reliability: .reliable, durability: .volatile, history: .keepLast(2_000))
    let ctx = try await ROS2Context(transport: transportConfig())
    // Deliberate opt-out (not an rcl limitation): the parameter stack works
    // on every backend, but six idle services + a /parameter_events
    // publisher would add discovery traffic to a latency benchmark.
    let node = try await ctx.createNode(
        name: "rcl_bench", namespace: "/rcl_bench",
        options: ROS2NodeOptions(startParameterServices: false))

    let collector = Collector(capacity: count)
    // Warmup messages carry stamp 0 (never stamped) — skip them so the
    // latency stats and the received count cover the measured window only.
    @Sendable func recordStamped(_ t: Time) {
        let s = stampedNS(t)
        if s != 0 { collector.record(nowNS() &- s) }
    }
    let isRoundtrip = mode == "roundtrip" || mode == "roundtrip-lan"
    let subTopic = mode == "roundtrip-lan" ? "bench_echo" : "bench"
    if isRoundtrip {
        switch payload {
        case "imu":
            let sub = try await node.createSubscription(Imu.self, topic: subTopic, qos: qos)
            sub.onMessage { m in recordStamped(m.header.stamp) }
        case "image64k":
            let sub = try await node.createSubscription(
                CompressedImage.self, topic: subTopic, qos: qos)
            sub.onMessage { m in recordStamped(m.header.stamp) }
        default:
            let sub = try await node.createSubscription(
                PointCloud2.self, topic: subTopic, qos: qos)
            sub.onMessage { m in recordStamped(m.header.stamp) }
        }
    }

    // Per-payload publish loops (kept monomorphic for stable measurement).
    var callNS: [UInt64] = []
    callNS.reserveCapacity(count)
    let periodNS: UInt64 = rateHz > 0 ? UInt64(1_000_000_000 / rateHz) : 0
    var wall: Double = 0

    func loop<M: CDREncodable & ROS2MessageType>(_ proto: M.Type, _ make: () -> M, _ stamp: @escaping (inout M) -> Void)
        async throws
    {
        let pub = try await node.createPublisher(M.self, topic: "bench", qos: qos)
        // Discovery settle (repo precedent: 2 s loopback, 3 s LAN).
        try await Task.sleep(for: .seconds(mode == "roundtrip-lan" ? 3 : 2))
        var msg = make()
        for _ in 0..<warmup { try await pub.publish(msg) }
        let start = nowNS()
        var next = start
        for _ in 0..<count {
            if periodNS > 0 {
                next &+= periodNS
                let now = nowNS()
                if next > now { try await Task.sleep(for: .nanoseconds(Int64(next - now))) }
            }
            stamp(&msg)
            let t0 = nowNS()
            try await pub.publish(msg)
            callNS.append(nowNS() - t0)
        }
        wall = Double(nowNS() - start) / 1e9
    }

    switch payload {
    case "imu":
        try await loop(Imu.self, makeImu) { stampNow(&$0.header.stamp) }
    case "image64k":
        try await loop(CompressedImage.self, makeImage64k) { stampNow(&$0.header.stamp) }
    default:
        try await loop(PointCloud2.self, makeCloud120k) { stampNow(&$0.header.stamp) }
    }

    var received = collector.snapshot.count
    if isRoundtrip {
        // Drain window for in-flight messages.
        let deadline = nowNS() + 5_000_000_000
        while received < count && nowNS() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            received = collector.snapshot.count
        }
    }

    let p = isRoundtrip ? percentiles(collector.snapshot) : percentiles(callNS)
    printResult([
        "backend": backend, "stack": HarnessCLI.stack(forBackend: backend),
        "mode": mode, "payload": payload, "count": "\(count)",
        "received": isRoundtrip ? "\(received)" : "-",
        "rate_hz": rateHz > 0 ? "\(rateHz)" : "max",
        "msgs_per_s": String(format: "%.0f", Double(count) / wall),
        "p50us": String(format: "%.2f", p.p50), "p95us": String(format: "%.2f", p.p95),
        "p99us": String(format: "%.2f", p.p99), "maxus": String(format: "%.2f", p.max),
        "wall_s": String(format: "%.3f", wall),
    ])
    await ctx.shutdown()
}

// MARK: - main

if mode == "encode" {
    try runEncode()
    exit(0)
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        try await runPubSub()
    } catch {
        print("rcl_bench FAIL: \(error)")
        fflush(stdout)
        exit(1)
    }
    done.signal()
}
done.wait()
exit(0)
