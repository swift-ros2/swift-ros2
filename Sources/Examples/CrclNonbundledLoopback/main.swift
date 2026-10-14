// crcl-nonbundled-loopback — route-(b) non-bundled publish runtime gate.
//
// This is the runtime proof for publishing an UNBUNDLED type on the RCL
// backend. audio_common_msgs/AudioData is absent from the 12-entry marshal
// registry, so crcl_publisher_create rejects it; RclClient.createPublisher
// then falls back to the CDDSBridge raw-CDR writer below rmw (route (b)) —
// a sibling CycloneDDS participant on the rcl context's domain.
//
// Receipt is verified by a SECOND, pure-Swift `.dds` (wire) backend
// AudioData subscription on the SAME domain. Subscribe-of-non-bundled is
// intentionally deferred on RCL (Conduit is publish-only), so the wire
// backend is the receiver. Both the route-(b) raw writer and the `.dds`
// subscriber are CDDSBridge participants on domain 0 (linked against the
// standalone CCycloneDDS, or, in a route-(B) graph, against the CycloneDDS
// inside the RCL xcframework — the same one rmw_cyclonedds_cpp runs on); they
// interoperate in-process with the rcl participants — exactly the runtime
// co-existence this gate proves.
//
// On success prints "crcl_nonbundled_loopback OK" + flush, then exits 0
// (before context teardown, which can block on headless runners — ci-rcl
// bounds the run with SIGALRM and decides success on the OK line, consistent
// with crcl-loopback / crcl-svc-loopback / crcl-smoke).

import Foundation
import SwiftROS2

// Last-resort in-process bound (20 s): the receive deadline below is 15 s
// (2 s settle + ~13 s publish/receive window). If the route-(b) writer and the
// wire subscriber never match, SIGALRM fires the handler, which prints a FAIL
// line and exits 1 so the CI grep fails deterministically.
let sigalrmHandler: @convention(c) (Int32) -> Void = { _ in
    let msg = "crcl_nonbundled_loopback FAIL: SIGALRM — wire subscriber did not receive route-b AudioData\n"
    _ = msg.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    _exit(1)
}
signal(SIGALRM, sigalrmHandler)
alarm(20)

func fail(_ reason: String) -> Never {
    print("crcl_nonbundled_loopback FAIL: \(reason)")
    fflush(stdout)
    exit(1)
}

// Deterministic 4-byte payload — discriminates a correct round-trip from an
// empty / wrong receipt.
let fixture = AudioData(data: Data([0xDE, 0xAD, 0xBE, 0xEF]))

/// Lock-protected capture of the last AudioData received by the wire subscriber.
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

// --- Publisher context first: `.rcl` backend ------------------------------
// rcl's CycloneDDS must create the process domain object first. The CDDSBridge
// participants below (the wire `.dds` subscriber and the route-(b) raw session)
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
        name: "nonbundled_loopback_tx", namespace: "/loopback")
} catch {
    fail("RCL createNode threw: \(error)")
}

// --- Receiver: pure-Swift `.dds` (wire) backend on the SAME domain 0 ------
// Bind the subscriber before the route-(b) writer sends so SEDP advertises the
// reader first.
let ddsCtx: ROS2Context
do {
    ddsCtx = try await ROS2Context(transport: .ddsMulticast(domainId: 0))
} catch {
    fail("DDS ROS2Context creation threw: \(error)")
}

let ddsNode: ROS2Node
do {
    ddsNode = try await ddsCtx.createNode(
        name: "nonbundled_loopback_rx", namespace: "/loopback")
} catch {
    fail("DDS createNode threw: \(error)")
}

let sub: ROS2Subscription<AudioData>
do {
    sub = try await ddsNode.createSubscription(AudioData.self, topic: "loopback_audio")
} catch {
    fail("DDS createSubscription threw: \(error)")
}

let box = ReceiveBox()
let consumer = Task {
    for await message in sub.messages {
        box.record(message.data)
    }
}

// --- route-(b) publisher: AudioData is unbundled, so createPublisher misses
// the marshal registry and falls back to the CDDSBridge raw-CDR writer below
// rmw (a sibling participant joining the shared domain).
let pub: ROS2Publisher<AudioData>
do {
    pub = try await rclNode.createPublisher(AudioData.self, topic: "loopback_audio")
} catch {
    fail("RCL createPublisher (route-b) threw: \(error)")
}

// DDS endpoint discovery (SPDP/SEDP) needs a moment even in-process — repo
// precedent is the 2 s settle in DDSRoundTripTests.testLoopbackPubSubSameProcess.
try? await Task.sleep(nanoseconds: 2_000_000_000)

// Publish at ~10 Hz until the wire subscriber has the payload or the deadline
// passes. Publishing keeps going during the receive window so a late
// reader-writer match cannot starve the gate.
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
    fail("wire subscriber received no AudioData within 13 s (published \(published))")
}

precondition(received == Data([0xDE, 0xAD, 0xBE, 0xEF]), "data mismatch: \(Array(received))")

print("crcl_nonbundled_loopback OK")
fflush(stdout)

// Best-effort teardown after the OK line: on a headless runner CycloneDDS
// teardown can block, and ci-rcl's SIGALRM bound + OK-line grep absorb that.
consumer.cancel()
await ddsCtx.shutdown()
await rclCtx.shutdown()
exit(0)
