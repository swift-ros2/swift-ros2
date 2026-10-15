// rcl-soak — endurance / leak harness (design §5 Axis 2). Streams a corpus
// payload at a fixed rate for a bounded duration, samples RSS + open-FD count
// + throughput on an interval, prints the time series, and reports the
// SoakAnalysis verdict. Built for long soak runs; `--selftest` does a fast
// 2 s in-process smoke that asserts the harness itself works.
//
// Usage:
//   rcl-soak <rcl|dds|zenoh> [imu|image64k|cloud120k] [--duration-s N] [--sample-s N]
//            [--rate-hz N] [--domain N] [--locator STR] [--selftest]
//            [--inject-malformed] [--expect-echo]
//
// The `zenoh` backend resolves to the zenoh-pico wire path on the default
// build and to rcl + rmw_zenoh_cpp on the SWIFT_ROS2_RCL_RMW=zenoh variant;
// its router locator comes from `--locator`, then SWIFT_ROS2_ZENOH_LOCATOR,
// then tcp/127.0.0.1:7447. With `--expect-echo` the host relays `soak` ->
// `soak_echo` (e.g. `ros2 run topic_tools relay`) and the harness counts
// deliveries on the echo topic.
//
// Output: per-sample `rcl_soak SAMPLE t=.. rss_mb=.. fds=.. msgs_per_s=..`
//         (plus `recv_per_s=..` with --expect-echo) then a final
//         `rcl_soak RESULT verdict=.. rss_slope_b_per_min=.. ...`.

import Darwin
import Dispatch
import Foundation
import SwiftROS2
import SwiftROS2Bench
import SwiftROS2RCL
import SwiftROS2TestFixtures

// MARK: - CLI

let args = CommandLine.arguments
func flag(_ name: String) -> Bool { args.contains(name) }
func intOpt(_ name: String, _ def: Int) -> Int {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else {
        return def
    }
    return v
}

let selftest = flag("--selftest")
let backend = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "rcl"
let payload = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : "imu"
let durationS = intOpt("--duration-s", selftest ? 2 : 3600)
let sampleS = intOpt("--sample-s", selftest ? 1 : 30)
let rateHz = intOpt("--rate-hz", 100)
let domainId = intOpt("--domain", 42)
let injectMalformed = flag("--inject-malformed")
let expectEcho = flag("--expect-echo")
let zenohLocator = HarnessCLI.resolveZenohLocator(
    arguments: args, environment: ProcessInfo.processInfo.environment)

guard HarnessCLI.supportedBackends.contains(backend),
    ["imu", "image64k", "cloud120k"].contains(payload)
else {
    print(
        "rcl_soak FAIL: usage: rcl-soak <rcl|dds|zenoh> [imu|image64k|cloud120k] [--duration-s N] ..."
    )
    exit(2)
}

// MARK: - resource sampling (Darwin)

@inline(__always) func nowNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func currentRSSBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

/// Open file descriptors = entries under /dev/fd on Darwin.
func openFDCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

// MARK: - payloads (mirror rcl-bench)

func makeImu() -> Imu {
    Imu(
        header: Header(stamp: Time(sec: 0, nanosec: 0), frameId: "soak"),
        orientation: Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.4),
        orientationCovariance: [0, 1, 2, 3, 4, 5, 6, 7, 8],
        angularVelocity: Vector3(x: 1.5, y: 2.5, z: 3.5),
        angularVelocityCovariance: [9, 10, 11, 12, 13, 14, 15, 16, 17],
        linearAcceleration: Vector3(x: 9.8, y: 0.0, z: -9.8),
        linearAccelerationCovariance: [18, 19, 20, 21, 22, 23, 24, 25, 26])
}
func makeImage64k() -> CompressedImage {
    CompressedImage(
        header: Header(stamp: Time(sec: 0, nanosec: 0), frameId: "soak"),
        format: "jpeg", data: (0..<65_536).map { UInt8($0 & 0xFF) })
}
func makeCloud120k() -> PointCloud2 {
    PointCloud2(
        header: Header(stamp: Time(sec: 0, nanosec: 0), frameId: "soak"),
        height: 1, width: 10_000,
        fields: [
            PointField(name: "x", offset: 0, datatype: 7, count: 1),
            PointField(name: "y", offset: 4, datatype: 7, count: 1),
            PointField(name: "z", offset: 8, datatype: 7, count: 1),
        ],
        isBigendian: false, pointStep: 12, rowStep: 120_000,
        data: (0..<120_000).map { UInt8($0 & 0xFF) }, isDense: true)
}

// MARK: - publish counter (delivery-thread safe)

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int) {
        lock.lock()
        n += k
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

func run() async throws {
    let qos = QoSProfile(reliability: .reliable, durability: .volatile, history: .keepLast(64))
    let config: TransportConfig
    switch backend {
    case "rcl": config = .rcl(domainId: domainId)
    case "zenoh": config = .zenoh(locator: zenohLocator, domainId: domainId)
    default: config = .ddsMulticast(domainId: domainId)
    }
    let ctx = try await ROS2Context(transport: config)
    let node = try await ctx.createNode(
        name: "rcl_soak", namespace: "/rcl_soak",
        options: ROS2NodeOptions(startParameterServices: false))

    // Optional resilience probe: open a subscription for a type the publisher
    // never sends, exercising the receive path's empty-queue handling for the
    // whole run (a cheap stand-in for malformed-receive robustness).
    if injectMalformed {
        let probe = try await node.createSubscription(Imu.self, topic: "soak_absent", qos: qos)
        probe.onMessage { _ in }
    }

    // H7 receive-side observability: with --expect-echo the host relays
    // `soak` -> `soak_echo` and we count deliveries on the echo topic,
    // mirroring rcl-bench's roundtrip-lan subscription.
    let received = Counter()
    if expectEcho {
        switch payload {
        case "imu":
            let sub = try await node.createSubscription(Imu.self, topic: "soak_echo", qos: qos)
            sub.onMessage { _ in received.add(1) }
        case "image64k":
            let sub = try await node.createSubscription(
                CompressedImage.self, topic: "soak_echo", qos: qos)
            sub.onMessage { _ in received.add(1) }
        default:
            let sub = try await node.createSubscription(
                PointCloud2.self, topic: "soak_echo", qos: qos)
            sub.onMessage { _ in received.add(1) }
        }
    }

    let published = Counter()
    let periodNS: UInt64 = rateHz > 0 ? UInt64(1_000_000_000 / UInt64(rateHz)) : 0

    func stream<M: CDREncodable & ROS2MessageType>(_ make: () -> M) async throws {
        let pub = try await node.createPublisher(M.self, topic: "soak", qos: qos)
        try await Task.sleep(for: .seconds(2))  // discovery settle
        let msg = make()
        let startNS = nowNS()
        let endNS = startNS + UInt64(durationS) * 1_000_000_000
        var samples: [SoakSample] = []
        var recvSeries: [Double] = []
        var nextSampleNS = startNS + UInt64(sampleS) * 1_000_000_000
        var lastSampleCount = 0
        var lastRecvCount = 0
        var lastSampleNS = startNS
        var lastFDs = max(0, openFDCount())  // baseline; carried if a read fails
        var next = startNS
        while nowNS() < endNS {
            if periodNS > 0 {
                next &+= periodNS
                let now = nowNS()
                if next > now { try await Task.sleep(for: .nanoseconds(Int64(next - now))) }
            }
            try await pub.publish(msg)
            published.add(1)

            let now = nowNS()
            if now >= nextSampleNS {
                let total = published.value
                let dt = Double(now - lastSampleNS) / 1e9
                let mps = dt > 0 ? Double(total - lastSampleCount) / dt : 0
                let rawFDs = openFDCount()
                let fds = rawFDs >= 0 ? rawFDs : lastFDs  // carry last good on a failed read
                lastFDs = fds
                let recvTotal = received.value
                let recvPerS = dt > 0 ? Double(recvTotal - lastRecvCount) / dt : 0
                let s = SoakSample(
                    tSeconds: Double(now - startNS) / 1e9, rssBytes: currentRSSBytes(),
                    openFDs: fds, msgsPerSec: mps)
                samples.append(s)
                if expectEcho { recvSeries.append(recvPerS) }
                print(
                    "rcl_soak SAMPLE t=\(String(format: "%.1f", s.tSeconds)) "
                        + "rss_mb=\(String(format: "%.1f", Double(s.rssBytes) / 1_048_576)) "
                        + "fds=\(s.openFDs) msgs_per_s=\(String(format: "%.0f", s.msgsPerSec))"
                        + (expectEcho ? " recv_per_s=\(String(format: "%.0f", recvPerS))" : ""))
                fflush(stdout)
                lastSampleCount = total
                lastRecvCount = recvTotal
                lastSampleNS = now
                nextSampleNS = now + UInt64(sampleS) * 1_000_000_000
            }
        }
        let v = SoakAnalysis.analyze(samples)
        var result =
            "rcl_soak RESULT backend=\(backend) stack=\(HarnessCLI.stack(forBackend: backend)) "
            + "payload=\(payload) duration_s=\(durationS) "
            + "samples=\(samples.count) published=\(published.value) "
            + "verdict=\(v.leakSuspected ? "LEAK" : "healthy") "
            + "rss_slope_b_per_min=\(Int(v.rssSlopeBytesPerMin.rounded())) "
            + "fd_growth=\(v.fdGrowth) "
            + "tput_degradation_pct=\(String(format: "%.1f", v.throughputDegradationPct))"
        if expectEcho {
            // A sample counts as stalled below half the target publish rate —
            // a strict zero-only check misses partial outages (e.g. a router
            // restart inside one window), and the first window is excluded
            // while the relay/subscription match warms up.
            let stallThreshold = Double(rateHz) * 0.5
            let echo = SoakAnalysis.echoContinuity(
                recvPerSecond: recvSeries, stallThreshold: stallThreshold, excludeWarmup: true)
            result +=
                " received=\(received.value)"
                + " recv_stall_threshold=\(String(format: "%.0f", stallThreshold))"
                + " recv_stall_run_max=\(echo.maxConsecutiveZeroRecvSamples)"
                + " recv_recovered=\(echo.recoveredAfterZeroRecv)"
        }
        print(result)
        fflush(stdout)
        if selftest {
            guard samples.count >= 1, samples.allSatisfy({ $0.rssBytes > 0 }) else {
                print("rcl_soak FAIL: selftest produced no valid samples")
                await ctx.shutdown()
                exit(1)
            }
            print("rcl_soak SELFTEST OK")
        }
    }

    switch payload {
    case "imu": try await stream(makeImu)
    case "image64k": try await stream(makeImage64k)
    default: try await stream(makeCloud120k)
    }
    await ctx.shutdown()
}

let done = DispatchSemaphore(value: 0)
Task {
    do { try await run() } catch {
        print("rcl_soak FAIL: \(error)")
        fflush(stdout)
        exit(1)
    }
    done.signal()
}
done.wait()
exit(0)
