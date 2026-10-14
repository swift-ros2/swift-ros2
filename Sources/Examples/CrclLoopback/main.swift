// crcl-loopback — M4 subscribe round-trip gate.
//
// One process, one rcl context: an rcl publisher and an rcl subscription on
// sensor_msgs/Imu share the topic "loopback_imu". The publisher sends a
// deterministic Imu fixture; every received message has travelled
// CDREncoder -> rcl_publish_serialized_message -> CycloneDDS in-process
// delivery -> rcl_take_serialized_message -> CDRDecoder, i.e. the full public
// createPublisher / createSubscription surface end-to-end. On success prints
// "crcl_loopback OK: …" + flush, then exits 0 (before context teardown, which
// can block on headless runners — ci-rcl bounds the run with SIGALRM and
// decides success on the OK line, consistent with crcl-smoke).

import Foundation
import SwiftROS2
import SwiftROS2TestFixtures

func fail(_ reason: String) -> Never {
    print("crcl_loopback FAIL: \(reason)")
    fflush(stdout)
    exit(1)
}

// Deterministic fixture.
let fixture = Imu(
    header: Header(stamp: Time(sec: 1234, nanosec: 567_890_000), frameId: "imu_link"),
    orientation: Quaternion(x: 0.1, y: 0.2, z: 0.3, w: 0.4),
    orientationCovariance: [0, 1, 2, 3, 4, 5, 6, 7, 8],
    angularVelocity: Vector3(x: 1.5, y: 2.5, z: 3.5),
    angularVelocityCovariance: [9, 10, 11, 12, 13, 14, 15, 16, 17],
    linearAcceleration: Vector3(x: 9.8, y: 0.0, z: -9.8),
    linearAccelerationCovariance: [18, 19, 20, 21, 22, 23, 24, 25, 26]
)

/// Lock-protected receive counter + last-message capture, fed from the
/// AsyncStream consumer task and polled from the publish loop.
final class ReceiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var last: Imu?

    func record(_ message: Imu) {
        lock.lock()
        count += 1
        last = message
        lock.unlock()
    }

    var snapshot: (count: Int, last: Imu?) {
        lock.lock()
        defer { lock.unlock() }
        return (count, last)
    }
}

let ctx: ROS2Context
do {
    // CRCL_ZENOH_LOCATOR runs the same loopback over .zenoh(locator:): the
    // zenoh rmw variant rejects .rcl (which targets rmw_cyclonedds), so
    // ci-rcl's rcl-zenoh job points this at a router it starts.
    let transport: TransportConfig =
        ProcessInfo.processInfo.environment["CRCL_ZENOH_LOCATOR"].map { .zenoh(locator: $0) }
        ?? .rcl(domainId: 0)
    ctx = try await ROS2Context(transport: transport)
} catch {
    fail("ROS2Context creation threw: \(error)")
}

// Default ROS2NodeOptions: the parameter stack (six rcl_interfaces services
// + the /parameter_events emitter) works on .rcl, so the stock createNode
// path needs no opt-out.
let node: ROS2Node
do {
    node = try await ctx.createNode(
        name: "crcl_loopback",
        namespace: "/loopback"
    )
} catch {
    fail("createNode threw: \(error)")
}

// Reliable + deep history so the gate is deterministic once the reader and
// writer have matched; .sensorData (best-effort) would make drops legal.
let qos = QoSProfile(reliability: .reliable, durability: .volatile, history: .keepLast(50))

// Subscription first so the reader is advertised before the writer matches.
let sub: ROS2Subscription<Imu>
do {
    sub = try await node.createSubscription(Imu.self, topic: "loopback_imu", qos: qos)
} catch {
    fail("createSubscription threw: \(error)")
}

let box = ReceiveBox()
let consumer = Task {
    for await message in sub.messages {
        box.record(message)
    }
}

let pub: ROS2Publisher<Imu>
do {
    pub = try await node.createPublisher(Imu.self, topic: "loopback_imu", qos: qos)
} catch {
    fail("createPublisher threw: \(error)")
}

// DDS endpoint discovery (SPDP/SEDP) needs a moment even in-process — repo
// precedent is the 2 s settle in DDSRoundTripTests.testLoopbackPubSubSameProcess.
try? await Task.sleep(nanoseconds: 2_000_000_000)

// Publish at ~50 Hz until at least `target` messages went out AND at least
// `target` came back, or the deadline passes. Publishing keeps going during
// the receive window so a late reader-writer match cannot starve the gate.
let target = 20
let deadline = Date().addingTimeInterval(15)
var published = 0
while Date() < deadline {
    if published >= target && box.snapshot.count >= target { break }
    do {
        try pub.publish(fixture)
    } catch {
        fail("publish #\(published + 1) threw: \(error)")
    }
    published += 1
    try? await Task.sleep(nanoseconds: 20_000_000)
}

let (received, lastMessage) = box.snapshot
guard received >= target else {
    fail("received \(received)/\(target) messages within 15 s (published \(published))")
}
guard let last = lastMessage else {
    fail("received \(received) messages but captured none")
}

// Field-identity gate on discriminating fields of the last received message.
guard
    last.header.stamp.sec == fixture.header.stamp.sec,
    last.header.stamp.nanosec == fixture.header.stamp.nanosec
else {
    fail("stamp mismatch: \(last.header.stamp) != \(fixture.header.stamp)")
}
guard last.header.frameId == fixture.header.frameId else {
    fail("frame_id mismatch: \(last.header.frameId) != \(fixture.header.frameId)")
}
guard
    last.linearAcceleration.x == fixture.linearAcceleration.x,
    last.linearAcceleration.y == fixture.linearAcceleration.y,
    last.linearAcceleration.z == fixture.linearAcceleration.z
else {
    fail("linear_acceleration mismatch: \(last.linearAcceleration) != \(fixture.linearAcceleration)")
}
guard last.linearAccelerationCovariance.first == fixture.linearAccelerationCovariance.first else {
    fail(
        "linear_acceleration_covariance[0] mismatch: "
            + "\(String(describing: last.linearAccelerationCovariance.first)) != "
            + "\(String(describing: fixture.linearAccelerationCovariance.first))")
}

print("crcl_loopback OK: \(received) messages round-tripped (rcl serialized publish -> take -> CDRDecoder)")
fflush(stdout)

// Best-effort teardown after the OK line: on a headless runner CycloneDDS
// teardown can block, and ci-rcl's SIGALRM bound + OK-line grep absorb that.
consumer.cancel()
await ctx.shutdown()
exit(0)
