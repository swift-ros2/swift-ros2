// Latched std_msgs/String publisher — shows TRANSIENT_LOCAL on wire Zenoh.
// Publishes "latched-0" … "latched-<depth-1>" on /latched with reliable
// TRANSIENT_LOCAL keep-last(<depth>) QoS, then keeps running for 60 s so a
// subscriber that joins late (for example `ros2 topic echo --qos-durability
// transient_local /latched std_msgs/msg/String`) still receives the cached
// samples. The messages are published before any subscriber exists.
//
// Usage:
//   swift run latched-talker [tcp/<host>:7447] [domain_id] [depth] [distro]
//
// Arguments (all optional):
//   locator    router locator, default tcp/127.0.0.1:7447
//   domain_id  ROS 2 domain ID, default 0
//   depth      history depth, default 1 (values below 1 are raised to 1)
//   distro     wire format of the host: `humble` or `jazzy`, default `jazzy`
//              (`jazzy` also covers Kilted, Lyrical and Rolling)

import Foundation
import SwiftROS2

let args = CommandLine.arguments
let locator = args.count > 1 ? args[1] : "tcp/127.0.0.1:7447"
let domain = args.count > 2 ? Int(args[2]) ?? 0 : 0
let depth = args.count > 3 ? max(1, Int(args[3]) ?? 1) : 1
let distroName = args.count > 4 ? args[4].lowercased() : "jazzy"

let distro: ROS2Distro
switch distroName {
case "humble":
    distro = .humble
case "jazzy":
    distro = .jazzy
default:
    FileHandle.standardError.write(Data("Unknown distro '\(distroName)'. Use 'humble' or 'jazzy'.\n".utf8))
    exit(2)
}

let ctx = try await ROS2Context(
    transport: .zenoh(locator: locator, domainId: domain, wireMode: distro), distro: distro)
let node = try await ctx.createNode(name: "latched_talker", namespace: "/")
let qos = QoSProfile(reliability: .reliable, durability: .transientLocal, history: .keepLast(depth))
let pub = try await node.createPublisher(StringMsg.self, topic: "latched", qos: qos)
for i in 0..<depth {
    try pub.publish(StringMsg(data: "latched-\(i)"))
}
print("published \(depth) message(s) on /latched; waiting 60 s for late joiners")
try await Task.sleep(nanoseconds: 60_000_000_000)
await ctx.shutdown()
