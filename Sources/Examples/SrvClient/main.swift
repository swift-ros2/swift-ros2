// Minimal example_interfaces/srv/Trigger service client — mirrors demo_nodes_cpp/add_two_ints_client.cpp.
// Calls /trigger once and prints the response.
//
// Usage:
//   swift run srv-client zenoh [tcp/<host>:7447] [domain_id]
//   swift run srv-client dds   [domain_id]
//   swift run srv-client rcl   [domain_id]
//   swift run srv-client dds-unicast <peer> [domain_id]
//   swift run srv-client rcl-unicast <peer> [domain_id]

import Foundation
import SwiftROS2
import SwiftROS2ExampleInterfaces

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
let node = try await ctx.createNode(name: "srv_client")
let cli = try await node.createClient(TriggerSrv.self, name: "/trigger")

print("Waiting for /trigger...")
do {
    try await cli.waitForService(timeout: .seconds(5))
} catch {
    FileHandle.standardError.write(Data("Service did not appear: \(error)\n".utf8))
    await ctx.shutdown()
    exit(1)
}

do {
    let response = try await cli.call(.init(), timeout: .seconds(5))
    print("Response: success=\(response.success), message='\(response.message)'")
} catch {
    FileHandle.standardError.write(Data("Service call failed: \(error)\n".utf8))
    await ctx.shutdown()
    exit(1)
}

await ctx.shutdown()
