// crcl-nonbundled-sub-loopback — route-(b) non-bundled SUBSCRIBE runtime gate.
//
// Mirror of crcl-nonbundled-loopback with the roles swapped. An UNBUNDLED type
// (audio_common_msgs/AudioData, absent from the 12-entry marshal registry) is
// SUBSCRIBED on the RCL backend: createSubscription misses the registry and
// falls back to the CDDSBridge raw-CDR reader below rmw (route (b)) on a sibling
// CycloneDDS participant on the rcl context's domain.
//
// The sender is a SECOND, pure-Swift `.dds` (wire) AudioData publisher on the
// SAME domain. Both CDDSBridge participants (linked against the standalone
// CCycloneDDS, or, in a route-(B) graph, against the CycloneDDS inside the RCL
// xcframework — the same one rmw_cyclonedds_cpp runs on) interoperate
// in-process with the rcl participants — the runtime co-existence this gate
// proves.
//
// On success prints "crcl_nonbundled_sub_loopback OK" + flush, then exits 0
// before teardown (which can block on headless runners — ci-rcl bounds the run
// with SIGALRM and decides success on the OK line).

import Foundation
import SwiftROS2
import SwiftROS2TestFixtures

let sigalrmHandler: @convention(c) (Int32) -> Void = { _ in
    let msg =
        "crcl_nonbundled_sub_loopback FAIL: SIGALRM — route-b subscriber did not receive AudioData\n"
    _ = msg.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    _exit(1)
}
signal(SIGALRM, sigalrmHandler)
alarm(20)

func fail(_ reason: String) -> Never {
    print("crcl_nonbundled_sub_loopback FAIL: \(reason)")
    fflush(stdout)
    exit(1)
}

let fixture = AudioData(data: [0xDE, 0xAD, 0xBE, 0xEF])

final class ReceiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Data?
    func record(_ data: Data) {
        lock.lock()
        last = data
        lock.unlock()
    }
    var snapshot: Data? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

// --- Receiver context first: `.rcl` backend ------------------------------
// rcl's CycloneDDS must create the process domain object first. The CDDSBridge
// participants below (the route-(b) raw reader and the wire `.dds` publisher)
// then JOIN that domain via an implicit participant — their own
// dds_create_domain on the already-owned id fails gracefully and they fall
// through to the shared domain. The reverse order makes the wire bridge
// win the domain and rcl's rmw_create_node fails "Precondition Not Met".
let rclCtx: ROS2Context
do {
    rclCtx = try await ROS2Context(transport: .rcl(domainId: 0))
} catch {
    fail("RCL ROS2Context creation threw: \(error)")
}

let rclNode: ROS2Node
do {
    rclNode = try await rclCtx.createNode(
        name: "nonbundled_sub_loopback_rx", namespace: "/loopback")
} catch {
    fail("RCL createNode threw: \(error)")
}

// Unbundled type → createSubscription misses the registry and falls back to the
// route-(b) raw-CDR reader (creates the sibling participant on first use).
let sub: ROS2Subscription<AudioData>
do {
    sub = try await rclNode.createSubscription(AudioData.self, topic: "loopback_audio_sub")
} catch {
    fail("RCL createSubscription (route-b) threw: \(error)")
}

let box = ReceiveBox()
let consumer = Task {
    for await message in sub.messages {
        box.record(Data(message.data))
    }
}

// --- Sender: pure-Swift `.dds` (wire) backend on the SAME domain 0 --------
let ddsCtx: ROS2Context
do {
    ddsCtx = try await ROS2Context(transport: .ddsMulticast(domainId: 0))
} catch {
    fail("DDS ROS2Context creation threw: \(error)")
}

let ddsNode: ROS2Node
do {
    ddsNode = try await ddsCtx.createNode(
        name: "nonbundled_sub_loopback_tx", namespace: "/loopback")
} catch {
    fail("DDS createNode threw: \(error)")
}

let pub: ROS2Publisher<AudioData>
do {
    pub = try await ddsNode.createPublisher(AudioData.self, topic: "loopback_audio_sub")
} catch {
    fail("DDS createPublisher threw: \(error)")
}

// Endpoint discovery (SPDP/SEDP) needs a moment even in-process — repo precedent
// is the 2 s settle in DDSRoundTripTests.testLoopbackPubSubSameProcess.
try? await Task.sleep(nanoseconds: 2_000_000_000)

let deadline = Date().addingTimeInterval(13)
var published = 0
while Date() < deadline {
    if box.snapshot != nil { break }
    do {
        try pub.publish(fixture)
    } catch {
        fail("publish #\(published + 1) threw: \(error)")
    }
    published += 1
    try? await Task.sleep(nanoseconds: 100_000_000)
}

guard let received = box.snapshot else {
    fail("route-b subscriber received no AudioData within 13 s (published \(published))")
}

precondition(received == Data([0xDE, 0xAD, 0xBE, 0xEF]), "data mismatch: \(Array(received))")

print("crcl_nonbundled_sub_loopback OK")
fflush(stdout)

consumer.cancel()
await ddsCtx.shutdown()
await rclCtx.shutdown()
exit(0)
