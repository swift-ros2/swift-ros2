// crcl-action-loopback — action round-trip gate.
//
// One process, one rcl context, a Fibonacci action server and a Fibonacci
// action client sharing the name "fibonacci". Every exchange travels the full
// public createActionServer / createActionClient surface end-to-end:
// CDREncoder -> rmw_deserialize shim -> typed rcl_action server -> user
// handler (accept, per-step feedback, result) -> rmw_serialize shim ->
// rcl_action client wait thread -> CDRDecoder. Three phases:
//
// 1. Fibonacci(order: 5): send the goal, collect per-step feedback, await the
//    result and assert [0, 1, 1, 2, 3, 5] plus that the last feedback frame
//    matches the final sequence.
// 2. Fibonacci(order: 3): a second, sequential goal asserting [0, 1, 1, 2] —
//    a correlation bug (a result or feedback wired to the wrong goal id)
//    cannot satisfy both phases.
// 3. Cancel: send Fibonacci(order: 200) (~20 s at the server's 100 ms
//    per-step pacing — a horizon comfortably wider than any plausible runner
//    stall between the first feedback and the cancel delivery), wait for the
//    first feedback so execution is provably underway, cancel the goal, and
//    assert the terminal result is `.canceled` — the
//    same acknowledgement the wire path produces (server handleCancel
//    accepts, the executing Task is cancelled, GetResult returns
//    STATUS_CANCELED).
//
// On success prints "crcl_action_loopback OK: …" + flush, then exits 0
// (before context teardown, which can block on headless runners — ci-rcl
// bounds the run with SIGALRM and decides success on the OK line, consistent
// with crcl-loopback / crcl-svc-loopback).

import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces

// Last-resort in-process bound (120 s): the per-phase budgets below sum to
// ~100 s worst case (server wait 10 + phase-1 acceptance 10 / result 15 /
// feedback 10 + phase-2 acceptance 10 / result 15 + cancel-phase acceptance
// 10 / first-feedback 10 / cancel 5 / result 15 — typical runs settle in a
// few seconds) and stays under ci-rcl's outer 150 s bound. If anything wedges
// past every per-phase timeout, SIGALRM's default disposition kills the
// process before the OK line is printed, so the CI grep still fails
// deterministically.
alarm(120)

func fail(_ reason: String) -> Never {
    print("crcl_action_loopback FAIL: \(reason)")
    fflush(stdout)
    exit(1)
}

/// Lock-protected feedback capture — the feedback consumer runs on a child
/// task, the main flow polls snapshots against a deadline.
final class FeedbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[Int32]] = []

    func record(_ sequence: [Int32]) {
        lock.lock()
        frames.append(sequence)
        lock.unlock()
    }

    var snapshot: [[Int32]] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

/// Reference Fibonacci server (same shape as the wire-path example and the
/// upstream action_tutorials servers): seed [0, 1], append order - 1 terms,
/// publish feedback after every step, honor cooperative cancellation. The
/// 100 ms per-step pacing gives the cancel phase a real window while keeping
/// phases 1 and 2 sub-second.
actor LoopbackFibonacciHandler: ActionServerHandler {
    typealias Action = FibonacciAction

    private var pendingOrder: Int32 = 0

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse {
        guard goal.order > 0 else { return .reject }
        pendingOrder = goal.order
        return .accept
    }

    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
        return .accept
    }

    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws
        -> FibonacciAction.Result
    {
        let order = pendingOrder
        var sequence: [Int32] = [0, 1]
        for i in 1..<Int(order) {
            try Task.checkCancellation()
            if await handle.isCancelRequested {
                throw CancellationError()
            }
            sequence.append(sequence[i] + sequence[i - 1])
            try await handle.publishFeedback(FibonacciAction.Feedback(sequence: sequence))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return FibonacciAction.Result(sequence: sequence)
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

// Default ROS2NodeOptions on purpose — same stock createNode path the other
// gates exercise (parameter services + /parameter_events register alongside
// the action entities).
let node: ROS2Node
do {
    node = try await ctx.createNode(
        name: "crcl_action_loopback",
        namespace: "/loopback"
    )
} catch {
    fail("createNode threw: \(error)")
}

// Server first so all five action endpoints are advertised before the client
// starts looking for them.
do {
    _ = try await node.createActionServer(
        FibonacciAction.self,
        name: "fibonacci",
        handler: LoopbackFibonacciHandler()
    )
} catch {
    fail("createActionServer threw: \(error)")
}

let cli: ROS2ActionClient<FibonacciAction>
do {
    cli = try await node.createActionClient(FibonacciAction.self, name: "fibonacci")
} catch {
    fail("createActionClient threw: \(error)")
}

// Readiness via the seam's graph poll (rcl_action_server_is_available — all
// three services + both topics) instead of a blind sleep; in-process matching
// usually settles well under a second, but allow up to 10 s for slow ASan
// runners.
do {
    try await cli.waitForActionServer(timeout: .seconds(10))
} catch {
    fail("waitForActionServer threw: \(error)")
}

// --- Phase 1: Fibonacci(order: 5) -> [0, 1, 1, 2, 3, 5] + feedback ---

let firstHandle: ActionGoalHandle<FibonacciAction>
do {
    firstHandle = try await cli.sendGoal(
        FibonacciAction.Goal(order: 5), acceptanceTimeout: .seconds(10))
} catch {
    fail("sendGoal #1 threw: \(error)")
}
let firstFeedback = FeedbackBox()
let firstFeedbackConsumer = Task {
    for await fb in firstHandle.feedback {
        firstFeedback.record(fb.sequence)
    }
}

let expectedFirst: [Int32] = [0, 1, 1, 2, 3, 5]
do {
    let result = try await firstHandle.result(timeout: .seconds(15))
    guard case .succeeded(let r) = result else {
        fail("goal #1 terminal state is \(result), expected succeeded")
    }
    guard r.sequence == expectedFirst else {
        fail("goal #1 sequence mismatch: \(r.sequence) != \(expectedFirst)")
    }
} catch {
    fail("result #1 threw: \(error)")
}

// Feedback delivery is asynchronous relative to the result reply — give the
// consumer up to 10 s to drain the buffered frames. The server publishes one
// frame per step, so the final frame must equal the full sequence.
let feedbackDeadline = Date().addingTimeInterval(10)
while Date() < feedbackDeadline, firstFeedback.snapshot.last != expectedFirst {
    try? await Task.sleep(nanoseconds: 50_000_000)
}
firstFeedbackConsumer.cancel()
let firstFrames = firstFeedback.snapshot
guard let lastFrame = firstFrames.last, lastFrame == expectedFirst else {
    fail(
        "goal #1 feedback never reached \(expectedFirst) within 10 s "
            + "(received \(firstFrames.count) frames, last \(String(describing: firstFrames.last)))"
    )
}

// --- Phase 2: Fibonacci(order: 3) -> [0, 1, 1, 2] ---
//
// Sequential, after the first goal completed: a correlation bug cannot
// produce both expected sequences.

do {
    let secondHandle = try await cli.sendGoal(
        FibonacciAction.Goal(order: 3), acceptanceTimeout: .seconds(10))
    let result = try await secondHandle.result(timeout: .seconds(15))
    guard case .succeeded(let r) = result else {
        fail("goal #2 terminal state is \(result), expected succeeded")
    }
    guard r.sequence == [0, 1, 1, 2] else {
        fail("goal #2 sequence mismatch: \(r.sequence) != [0, 1, 1, 2]")
    }
} catch {
    fail("goal #2 threw: \(error)")
}

// --- Phase 3: cancel ---
//
// order=200 runs ~20 s at the server's pacing — wide enough that even a
// multi-second runner stall between the first feedback and the cancel
// delivery cannot let the goal complete and flip `.canceled` to
// `.succeeded`. The success path is unaffected: the cancel terminates the
// goal early. Wait for the first feedback frame so the executing Task is
// provably past acceptance before cancelling.

let cancelHandle: ActionGoalHandle<FibonacciAction>
do {
    cancelHandle = try await cli.sendGoal(
        FibonacciAction.Goal(order: 200), acceptanceTimeout: .seconds(10))
} catch {
    fail("sendGoal #3 threw: \(error)")
}
let cancelFeedback = FeedbackBox()
let cancelFeedbackConsumer = Task {
    for await fb in cancelHandle.feedback {
        cancelFeedback.record(fb.sequence)
    }
}
let executingDeadline = Date().addingTimeInterval(10)
while Date() < executingDeadline, cancelFeedback.snapshot.isEmpty {
    try? await Task.sleep(nanoseconds: 50_000_000)
}
guard !cancelFeedback.snapshot.isEmpty else {
    fail("goal #3 produced no feedback within 10 s — cannot exercise mid-flight cancel")
}

do {
    try await cancelHandle.cancel(timeout: .seconds(5))
} catch {
    fail("cancel threw: \(error)")
}

// The acknowledgement assertion, per the wire-path semantics: the server's
// handleCancel accepted, the executing Task observed the cancellation, and
// GetResult reports the terminal STATUS_CANCELED.
do {
    let result = try await cancelHandle.result(timeout: .seconds(15))
    guard case .canceled = result else {
        fail("goal #3 terminal state is \(result), expected canceled")
    }
} catch {
    fail("result #3 threw: \(error)")
}
cancelFeedbackConsumer.cancel()

print("crcl_action_loopback OK: Fibonacci(5) + Fibonacci(3) + cancel round-tripped")
fflush(stdout)

// Best-effort teardown after the OK line: on a headless runner CycloneDDS
// teardown can block, and ci-rcl's SIGALRM bound + OK-line grep absorb that.
await ctx.shutdown()
exit(0)
