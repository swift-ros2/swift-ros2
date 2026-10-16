// ParticipantEntitiesInfo.swift
// The `ros_discovery_info` record rmw_cyclonedds_cpp hosts read node names from.
//
// DDS discovery tells a host which participants, readers and writers exist,
// but not which ROS 2 node they belong to. rmw_dds_common's graph cache learns
// that only from the `ros_discovery_info` topic: every participant publishes
// one `rmw_dds_common/msg/ParticipantEntitiesInfo` listing its nodes and the
// gids of each node's readers and writers. Without it a host's `ros2 node list`
// does not show the participant's nodes, `ros2 param` cannot find them, and
// `ros2 topic info -v` reports `_NODE_NAME_UNKNOWN_` for their endpoints.

import Foundation
import SwiftROS2CDR
import SwiftROS2Wire

/// `rmw_dds_common/msg/ParticipantEntitiesInfo`:
///
/// ```
/// Gid gid                                  # the participant
/// NodeEntitiesInfo[] node_entities_info_seq
/// ```
///
/// with `NodeEntitiesInfo` = `string<=256 node_namespace`, `string<=256 node_name`,
/// `Gid[] reader_gid_seq`, `Gid[] writer_gid_seq`. A `Gid` is a fixed `char[N]`
/// array: N is 24 on Humble and 16 from Iron on. rmw_cyclonedds_cpp fills it with
/// the 16-byte DDS GUID that `dds_get_guid` returns, zero-padded on Humble.
package struct ParticipantEntitiesInfo: Equatable, Sendable {
    /// One node of the participant and the gids of its endpoints.
    package struct NodeEntities: Equatable, Sendable {
        package var namespace: String
        package var name: String
        package var readerGids: [[UInt8]]
        package var writerGids: [[UInt8]]

        package init(namespace: String, name: String, readerGids: [[UInt8]] = [], writerGids: [[UInt8]] = []) {
            self.namespace = namespace
            self.name = name
            self.readerGids = readerGids
            self.writerGids = writerGids
        }
    }

    /// The DDS topic the record is published on. It has no `rt/` prefix.
    package static let topicName = "ros_discovery_info"

    /// The DDS type name of the record.
    package static let ddsTypeName = "rmw_dds_common::msg::dds_::ParticipantEntitiesInfo_"

    /// RIHS01 hash of `rmw_dds_common/msg/ParticipantEntitiesInfo`, the same on
    /// Jazzy, Kilted and Lyrical (`ParticipantEntitiesInfo.json` in rmw_dds_common).
    package static let typeHash = "RIHS01_91a0593bacdcc50ea9bdcf849a938b128412cc1ea821245c663bcd26f83c295e"

    /// Byte length of a `rmw_dds_common/msg/Gid` on `distro`: `char[24]` on
    /// Humble, `char[16]` from Iron on.
    package static func gidSize(for distro: ROS2Distro) -> Int {
        distro.isLegacySchema ? 24 : 16
    }

    /// The writer USER_DATA rmw_cyclonedds_cpp sets on its `ros_discovery_info`
    /// writer: the type hash on distributions that have one.
    package static func userData(for distro: ROS2Distro) -> String? {
        DDSWireCodec().userDataString(typeHash: distro.supportsTypeHash ? typeHash : nil)
    }

    package var participantGid: [UInt8]
    package var nodes: [NodeEntities]

    package init(participantGid: [UInt8], nodes: [NodeEntities] = []) {
        self.participantGid = participantGid
        self.nodes = nodes
    }

    /// The XCDR v1 little-endian sample, encapsulation header included, with
    /// every gid zero-padded (or cut) to `gidSize` bytes.
    package func encode(gidSize: Int) -> Data {
        let encoder = CDREncoder(estimatedSize: 64 + nodes.count * 128)
        encoder.writeEncapsulationHeader()
        func writeGid(_ gid: [UInt8]) {
            let bytes = Array(gid.prefix(gidSize))
            encoder.writeRawBytes(bytes)
            encoder.writePadding(gidSize - bytes.count)
        }
        writeGid(participantGid)
        encoder.writeUInt32(UInt32(nodes.count))
        for node in nodes {
            encoder.writeString(node.namespace)
            encoder.writeString(node.name)
            encoder.writeUInt32(UInt32(node.readerGids.count))
            node.readerGids.forEach(writeGid)
            encoder.writeUInt32(UInt32(node.writerGids.count))
            node.writerGids.forEach(writeGid)
        }
        return encoder.getData()
    }

    /// Decodes a sample with `gidSize`-byte gids, as ``encode(gidSize:)`` or
    /// rmw_cyclonedds_cpp writes it.
    package init(decoding data: Data, gidSize: Int) throws {
        try self.init(decoder: CDRDecoder(data: data), gidSize: gidSize)
    }

    /// Decodes a record received on `ros_discovery_info`, whose gid size depends on the
    /// sender's distribution: `preferredGidSize` first, then the other size (16 or 24).
    /// A size is accepted only when the record ends exactly where the sample does, after
    /// dropping the padding its encapsulation options announce; `nil` when neither fits.
    package static func decodeReceived(_ data: Data, preferredGidSize: Int) -> ParticipantEntitiesInfo? {
        guard data.count >= 4 else { return nil }
        // XCDR1 puts the number of padding bytes at the end of the sample in the low
        // two bits of the options. `CDRDecoder` accepts only zero options.
        var sample = Data(data)
        let padding = Int(sample[3] & 0x3)
        guard sample.count >= 4 + padding else { return nil }
        sample.removeLast(padding)
        sample[2] = 0
        sample[3] = 0
        for gidSize in [preferredGidSize, preferredGidSize == 24 ? 16 : 24] {
            guard let decoder = try? CDRDecoder(data: sample),
                let info = try? ParticipantEntitiesInfo(decoder: decoder, gidSize: gidSize),
                decoder.remainingBytes == 0
            else { continue }
            return info
        }
        return nil
    }

    private init(decoder: CDRDecoder, gidSize: Int) throws {
        func readGids(count: Int) throws -> [[UInt8]] {
            try (0..<count).map { _ in try (0..<gidSize).map { _ in try decoder.readUInt8() } }
        }
        participantGid = try readGids(count: 1)[0]
        nodes = try (0..<decoder.readSequenceCount()).map { _ in
            let namespace = try decoder.readString()
            let name = try decoder.readString()
            let readers = try readGids(count: decoder.readSequenceCount())
            let writers = try readGids(count: decoder.readSequenceCount())
            return NodeEntities(namespace: namespace, name: name, readerGids: readers, writerGids: writers)
        }
    }
}
