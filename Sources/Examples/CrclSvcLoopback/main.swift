// crcl-svc-loopback — M7 service + parameter round-trip gate.
//
// One process, one rcl context, two phases:
//
// 1. Services: a service server and a service client for
//    example_interfaces/AddTwoInts share the name "add_two_ints". Every call
//    travels the full public createService / createClient surface end-to-end:
//    CDREncoder -> rmw_deserialize shim -> typed rcl service server ->
//    user handler -> rmw_serialize shim -> rcl_take_response -> CDRDecoder.
//    Two sequential calls with distinct operands discriminate correlation
//    bugs (a response wired to the wrong request cannot satisfy both sums).
//
// 2. Parameters: the node is created with DEFAULT ROS2NodeOptions — the
//    first time the stock createNode path runs on .rcl — so the six
//    rcl_interfaces parameter services register at creation and
//    /parameter_events publishes over the registry-only serialized seam
//    (zero parameter-specific transport work). A ROS2ParameterClient
//    pointed at the node's own services declares/gets/sets a parameter and
//    a /parameter_events subscription asserts the change event arrives.
//
// On success prints "crcl_svc_loopback OK: …" + flush, then exits 0 (before
// context teardown, which can block on headless runners — ci-rcl bounds the
// run with SIGALRM and decides success on the OK line, consistent with
// crcl-loopback / crcl-smoke).

import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces

// Last-resort in-process bound (120 s): the per-phase budgets below sum to
// ~55 s worst case (service waitForService 10 + two 5 s calls + param
// waitForService 10 + three 5 s param calls + 10 s event wait — typical runs
// settle in seconds) and ASan startup adds more, so leave real headroom while
// staying under ci-rcl's outer 150 s bound. If anything wedges past every
// per-phase timeout, SIGALRM's default disposition kills the process before
// the OK line is printed, so the CI grep still fails deterministically.
alarm(120)

func fail(_ reason: String) -> Never {
    print("crcl_svc_loopback FAIL: \(reason)")
    fflush(stdout)
    exit(1)
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

// Default ROS2NodeOptions on purpose: createNode itself registers the six
// rcl_interfaces parameter services and installs the /parameter_events
// emitter, so this single node serves both the AddTwoInts phase and the
// parameter phase below.
let node: ROS2Node
do {
    node = try await ctx.createNode(
        name: "crcl_svc_loopback",
        namespace: "/loopback"
    )
} catch {
    fail("createNode threw: \(error)")
}

// Server first so the reader/writer pairs are advertised before the client
// starts looking for them.
do {
    _ = try await node.createService(AddTwoIntsSrv.self, name: "add_two_ints") { request in
        AddTwoIntsResponse(sum: request.a + request.b)
    }
} catch {
    fail("createService threw: \(error)")
}

let cli: ROS2Client<AddTwoIntsSrv>
do {
    cli = try await node.createClient(AddTwoIntsSrv.self, name: "add_two_ints")
} catch {
    fail("createClient threw: \(error)")
}

// Readiness via the seam's graph poll (rcl_service_server_is_available)
// instead of a blind sleep — in-process SEDP matching usually settles well
// under a second, but allow up to 10 s for slow ASan runners.
do {
    try await cli.waitForService(timeout: .seconds(10))
} catch {
    fail("waitForService threw: \(error)")
}

// Two sequential calls with distinct operands — a correlation bug (response
// resolved against the wrong request) cannot produce both expected sums.
let first: AddTwoIntsResponse
do {
    first = try await cli.call(AddTwoIntsRequest(a: 2, b: 3), timeout: .seconds(5))
} catch {
    fail("call #1 threw: \(error)")
}
guard first.sum == 5 else {
    fail("call #1 sum mismatch: \(first.sum) != 5")
}

let second: AddTwoIntsResponse
do {
    second = try await cli.call(AddTwoIntsRequest(a: -7, b: 40), timeout: .seconds(5))
} catch {
    fail("call #2 threw: \(error)")
}
guard second.sum == 33 else {
    fail("call #2 sum mismatch: \(second.sum) != 33")
}

// --- Parameter phase ---
//
// Subscribe to /parameter_events before any parameter mutation so the
// change event cannot race the reader-writer match (the publisher QoS is
// transient-local, but the gate shouldn't have to rely on replay).
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ParameterEvent] = []

    func record(_ event: ParameterEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [ParameterEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

let eventBox = EventBox()
let eventSub: ROS2Subscription<ParameterEvent>
do {
    eventSub = try await node.createSubscription(
        ParameterEvent.self, topic: "/parameter_events", qos: .parameterEvents)
} catch {
    fail("createSubscription(/parameter_events) threw: \(error)")
}
let eventConsumer = Task {
    for await event in eventSub.messages {
        eventBox.record(event)
    }
}

// Declare locally; the lazy /parameter_events publisher spins up on this
// first mutation (registry-only rcl_interfaces/msg/ParameterEvent entry
// over the serialized seam).
do {
    let declared = try await node.declareParameter("answer", default: Int64(41))
    guard declared == 41 else {
        fail("declareParameter returned \(declared), expected 41")
    }
} catch {
    fail("declareParameter threw: \(error)")
}

// Point a ROS2ParameterClient at this node's own six services — same
// in-process loopback shape as the AddTwoInts phase.
let paramClient: ROS2ParameterClient
do {
    paramClient = try await node.createParameterClient(remoteNode: node.fullyQualifiedName)
} catch {
    fail("createParameterClient threw: \(error)")
}
do {
    try await paramClient.waitForService(timeout: .seconds(10))
} catch {
    fail("parameter waitForService threw: \(error)")
}

// get -> declared value.
do {
    let values = try await paramClient.getParameters(["answer"], timeout: .seconds(5))
    guard values.count == 1, case .integer(let v) = values[0], v == 41 else {
        fail("param get #1 returned \(values), expected [.integer(41)]")
    }
} catch {
    fail("param get #1 threw: \(error)")
}

// set -> new value.
do {
    let results = try await paramClient.setParameters(
        [ROS2Parameter(name: "answer", value: .integer(42))], timeout: .seconds(5))
    guard results.count == 1, results[0].successful else {
        fail("param set rejected: \(results)")
    }
} catch {
    fail("param set threw: \(error)")
}

// get -> the value the set committed.
do {
    let values = try await paramClient.getParameters(["answer"], timeout: .seconds(5))
    guard values.count == 1, case .integer(let v) = values[0], v == 42 else {
        fail("param get #2 returned \(values), expected [.integer(42)]")
    }
} catch {
    fail("param get #2 threw: \(error)")
}

// The set must surface on /parameter_events as a changed-parameter event.
let eventDeadline = Date().addingTimeInterval(10)
var sawChange = false
while Date() < eventDeadline {
    if eventBox.snapshot.contains(where: { event in
        event.changedParameters.contains { $0.name == "answer" && $0.value.integerValue == 42 }
    }) {
        sawChange = true
        break
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
}
guard sawChange else {
    fail(
        "no /parameter_events change for 'answer' within 10 s "
            + "(received \(eventBox.snapshot.count) events)")
}

print(
    "crcl_svc_loopback OK: AddTwoInts 2+3=5, -7+40=33; "
        + "param declare/get/set + event round-tripped")
fflush(stdout)

// Best-effort teardown after the OK line: on a headless runner CycloneDDS
// teardown can block, and ci-rcl's SIGALRM bound + OK-line grep absorb that.
eventConsumer.cancel()
await paramClient.close()
await ctx.shutdown()
exit(0)
