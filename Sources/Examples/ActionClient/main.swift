// Minimal example_interfaces/action/Fibonacci client.
//
// Usage:
//   swift run action-client zenoh [tcp/<host>:7447] [domain_id] [order]
//   swift run action-client dds   [domain_id] [order]
//   swift run action-client rcl   [domain_id] [order]
//   swift run action-client dds-unicast <peer> [domain_id] [order]
//   swift run action-client rcl-unicast <peer> [domain_id] [order]

import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces

let args = Array(CommandLine.arguments.dropFirst())
let transportName = args.first ?? "zenoh"
let transport: TransportConfig
let order: Int32
switch transportName {
case "zenoh":
    let locator = args.dropFirst().first ?? "tcp/127.0.0.1:7447"
    let domainId = args.dropFirst(2).first.flatMap(Int.init) ?? 0
    order = args.dropFirst(3).first.flatMap(Int32.init) ?? 10
    transport = .zenoh(locator: locator, domainId: domainId)
case "dds":
    let domainId = args.dropFirst().first.flatMap(Int.init) ?? 0
    order = args.dropFirst(2).first.flatMap(Int32.init) ?? 10
    transport = .ddsMulticast(domainId: domainId)
case "rcl":
    let domainId = args.dropFirst().first.flatMap(Int.init) ?? 0
    order = args.dropFirst(2).first.flatMap(Int32.init) ?? 10
    transport = .rcl(domainId: domainId)
case "dds-unicast", "rcl-unicast":
    // <peer address> [domain] — exercises the discovery-XML builder.
    guard let peer = args.dropFirst().first else {
        FileHandle.standardError.write(Data("\(transportName) needs a peer address\n".utf8))
        exit(2)
    }
    let domainId = args.dropFirst(2).first.flatMap(Int.init) ?? 0
    order = args.dropFirst(3).first.flatMap(Int32.init) ?? 10
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
let node = try await ctx.createNode(name: "fibonacci_action_client")
let cli = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")

print("Waiting for /fibonacci server...")
do {
    try await cli.waitForActionServer(timeout: .seconds(5))
} catch {
    FileHandle.standardError.write(Data("Server did not appear: \(error)\n".utf8))
    await ctx.shutdown()
    exit(1)
}

print("Sending goal order=\(order)")
let handle = try await cli.sendGoal(FibonacciAction.Goal(order: order))
let feedbackTask = Task {
    for await fb in handle.feedback {
        print("Feedback: \(fb.sequence)")
    }
}
let result = try await handle.result()
feedbackTask.cancel()
switch result {
case .succeeded(let r): print("Succeeded: \(r.sequence)")
case .canceled: print("Canceled")
case .aborted(let r): print("Aborted: \(r ?? "nil")")
}
await ctx.shutdown()
