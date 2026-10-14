// Minimal example_interfaces/action/Fibonacci server.
//
// Usage:
//   swift run action-server zenoh [tcp/<host>:7447] [domain_id]
//   swift run action-server dds   [domain_id]
//   swift run action-server rcl   [domain_id]
//   swift run action-server dds-unicast <peer> [domain_id]
//   swift run action-server rcl-unicast <peer> [domain_id]

import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces

actor FibonacciHandler: ActionServerHandler {
    typealias Action = FibonacciAction

    private var pendingOrder: Int32 = 10

    func handleGoal(_ goal: FibonacciAction.Goal) async -> GoalResponse {
        print("Received Fibonacci goal: order=\(goal.order)")
        guard goal.order > 0 else { return .reject }
        pendingOrder = goal.order
        return .accept
    }

    func handleCancel(_ handle: ActionGoalHandle<FibonacciAction>) async -> CancelResponse {
        print("Received cancel request for goal=\(handle.goalId.uuidString)")
        return .accept
    }

    func execute(_ handle: ActionGoalHandle<FibonacciAction>) async throws
        -> FibonacciAction.Result
    {
        let order = pendingOrder
        var sequence: [Int32] = [0, 1]
        for _ in 0..<max(0, Int(order) - 2) {
            try Task.checkCancellation()
            if await handle.isCancelRequested {
                throw CancellationError()
            }
            sequence.append(sequence[sequence.count - 1] + sequence[sequence.count - 2])
            try await handle.publishFeedback(FibonacciAction.Feedback(sequence: sequence))
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return FibonacciAction.Result(sequence: sequence)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let transportName = args.first ?? "zenoh"
let transport: TransportConfig
switch transportName {
case "zenoh":
    let locator = args.dropFirst().first ?? "tcp/127.0.0.1:7447"
    let domainId = args.dropFirst(2).first.flatMap(Int.init) ?? 0
    transport = .zenoh(locator: locator, domainId: domainId)
case "dds":
    let domainId = args.dropFirst().first.flatMap(Int.init) ?? 0
    transport = .ddsMulticast(domainId: domainId)
case "rcl":
    let domainId = args.dropFirst().first.flatMap(Int.init) ?? 0
    transport = .rcl(domainId: domainId)
case "dds-unicast", "rcl-unicast":
    // <peer address> [domain] — exercises the discovery-XML builder.
    guard let peer = args.dropFirst().first else {
        FileHandle.standardError.write(Data("\(transportName) needs a peer address\n".utf8))
        exit(2)
    }
    let domainId = args.dropFirst(2).first.flatMap(Int.init) ?? 0
    let peers = [DDSPeer(address: peer, port: UInt16(7400 + domainId * 250))]
    transport =
        transportName == "rcl-unicast"
        ? .rclUnicast(peers: peers, domainId: domainId)
        : .ddsUnicast(peers: peers, domainId: domainId)
default:
    FileHandle.standardError.write(
        Data("Unknown transport '\(transportName)'. Use 'zenoh', 'dds', 'dds-unicast', 'rcl' or 'rcl-unicast'.\n".utf8))
    exit(2)
}

let ctx = try await ROS2Context(transport: transport, distro: .jazzy)
let node = try await ctx.createNode(name: "fibonacci_action_server")
let srv = try await node.createActionServer(
    FibonacciAction.self,
    name: "/fibonacci",
    handler: FibonacciHandler()
)
print("Action server /fibonacci ready (\(srv.name))")
while !Task.isCancelled {
    try await Task.sleep(nanoseconds: 1_000_000_000)
}
await ctx.shutdown()
