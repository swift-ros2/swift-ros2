// ActionFrameDecoder.swift
// Pure CDR helpers for action wrapper frames (send_goal / get_result / feedback / status).
//
// Both the DDS and Zenoh action transports call into these helpers; there is
// no I/O here. The byte layouts mirror what `rosidl_generator_cpp` emits for
// the synthesized wrappers, validated by `Tests/SwiftROS2CDRTests/ActionWrappersCDRTests.swift`
// (Phase 1) and the recorded wire dumps from Phase 2.

import Foundation
import SwiftROS2CDR

enum ActionFrameDecoderError: Error {
    case payloadTooShort
    case invalidCount(UInt32)
    case malformedFrame(String)
}

/// CDR helpers for the synthesized action wrapper frames.
///
/// Frames in/out of this enum carry exactly one 4-byte XCDR encapsulation
/// header (`00 01 00 00`), at offset 0 — the upstream `rosidl` layout that
/// real rmw peers (`rmw_cyclonedds_cpp`, `rmw_zenoh_cpp`, and `rmw_serialize`
/// on the `.rcl` transport) read. The transport calls `decode*` on incoming
/// wire payloads and `encode*` on outgoing wire payloads.
///
/// XCDR v1 aligns every primitive relative to the end of the encapsulation
/// header, i.e. to the start of the whole frame body, never to the start of a
/// nested struct. A user payload spliced into a frame is therefore only valid
/// when its own alignment origin falls on the same 8-byte boundary as its
/// position in the frame:
///
/// - Goal and feedback bodies follow the 16-byte goal UUID, so they start at
///   body offset 16 and a goal / feedback encoded on its own (origin 0) has
///   the same padding. They cross this boundary in the umbrella's shape:
///   `encode*` accepts them with or without a leading header and splices only
///   the bare body; `decode*` returns them with a leading header so
///   `CDRDecoder` can read them.
/// - The result follows a 1-byte status, so its padding (before its first
///   field and before every later 8-byte field) depends on that byte. The
///   result therefore crosses this boundary as the whole GetResult response,
///   `[header | status | result]`, encoded by one `CDREncoder`; see
///   `encodeGetResultResponse(status:resultCDR:)`.
enum ActionFrameDecoder {
    static let cdrHeader = Data([0x00, 0x01, 0x00, 0x00])

    /// The umbrella encodes every outbound user payload with a leading XCDR v1
    /// encapsulation header. Frames are consumed by real rmw peers, which expect
    /// the bare body at the splice offset (a Fibonacci goal would otherwise decode
    /// `order = 256`). Strip it before splicing.
    ///
    /// Precondition: `payload` is either umbrella-encoded (leading `00 01 00 00`)
    /// or bare. A *bare* payload whose first int32 happens to be 256 LE would be
    /// wrongly stripped — every caller today passes umbrella-encoded payloads.
    static func stripInnerEncapsulationHeader(_ payload: Data) -> Data {
        guard payload.count >= 4, payload.prefix(4) == cdrHeader else { return payload }
        return Data(payload.dropFirst(4))
    }

    /// Inbound bodies are always bare on the wire; hand the umbrella a payload
    /// `CDRDecoder` can read. Unconditional, so a body that merely *starts with*
    /// `00 01 00 00` (int32 256) is not mistaken for a header.
    private static func withHeader(_ body: Data) -> Data {
        var out = cdrHeader
        out.append(body)
        return out
    }

    /// Status array entry — one per goal currently tracked server-side.
    typealias StatusEntry = (uuid: [UInt8], stampSec: Int32, stampNanosec: UInt32, status: Int8)

    // MARK: - SendGoal request

    /// Wire shape: `[header (4) | uuid[16] | <bare user goal body>]`.
    /// `goalCDR` may carry the umbrella's encapsulation header; it is stripped.
    /// The goal starts at body offset 16 (a multiple of the largest XCDR v1
    /// alignment, 8), so a goal encoded from its own origin is laid out exactly
    /// as rosidl lays it out inside the request.
    static func encodeSendGoalRequest(goalId: [UInt8], goalCDR: Data) -> Data {
        precondition(goalId.count == 16, "goalId must be 16 bytes")
        let goalCDR = stripInnerEncapsulationHeader(goalCDR)
        var out = Data(capacity: 4 + 16 + goalCDR.count)
        out.append(cdrHeader)
        out.append(contentsOf: goalId)
        out.append(goalCDR)
        return out
    }

    /// Returns the goal body with a leading encapsulation header.
    static func decodeSendGoalRequest(from data: Data) throws -> (goalId: [UInt8], goalCDR: Data) {
        guard data.count >= 4 + 16 else { throw ActionFrameDecoderError.payloadTooShort }
        let goalId = Array(data[(data.startIndex + 4)..<(data.startIndex + 4 + 16)])
        let body = data.suffix(from: data.startIndex + 4 + 16)
        return (goalId, withHeader(Data(body)))
    }

    // MARK: - SendGoal response

    /// Wire shape: `[header (4) | accepted (1) | pad (3) | sec (i32 LE) | nanosec (u32 LE)]`.
    /// The 3-byte pad satisfies the int32 alignment after the bool.
    static func encodeSendGoalResponse(accepted: Bool, stampSec: Int32, stampNanosec: UInt32) -> Data {
        var out = Data(capacity: 4 + 1 + 3 + 4 + 4)
        out.append(cdrHeader)
        out.append(accepted ? 1 : 0)
        out.append(contentsOf: [0, 0, 0])
        var sec = stampSec.littleEndian
        var nsec = stampNanosec.littleEndian
        withUnsafeBytes(of: &sec) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &nsec) { out.append(contentsOf: $0) }
        return out
    }

    static func decodeSendGoalResponse(from data: Data) throws -> (
        accepted: Bool, stampSec: Int32, stampNanosec: UInt32
    ) {
        guard data.count >= 4 + 1 + 3 + 4 + 4 else { throw ActionFrameDecoderError.payloadTooShort }
        let base = data.startIndex
        let accepted = data[base + 4] != 0
        let sec = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: Int32.self).littleEndian
        }
        let nsec = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
        return (accepted, sec, nsec)
    }

    // MARK: - GetResult request

    /// Wire shape: `[header (4) | uuid[16]]`.
    static func encodeGetResultRequest(goalId: [UInt8]) -> Data {
        precondition(goalId.count == 16, "goalId must be 16 bytes")
        var out = Data(capacity: 4 + 16)
        out.append(cdrHeader)
        out.append(contentsOf: goalId)
        return out
    }

    static func decodeGetResultRequest(from data: Data) throws -> [UInt8] {
        guard data.count >= 4 + 16 else { throw ActionFrameDecoderError.payloadTooShort }
        return Array(data[(data.startIndex + 4)..<(data.startIndex + 4 + 16)])
    }

    // MARK: - GetResult response

    /// Wire shape: `[header (4) | status (i8) | <result>]`, where the result's
    /// padding is measured from the end of the header: none before a 1-byte
    /// first field, 3 bytes before a 4-byte one, 7 before an 8-byte one, and
    /// every later 8-byte field (float64, int64, a nested `Vector3`, ...)
    /// shifts with it. Only the encoder that wrote the result knows its field
    /// layout, so this function cannot re-align an independently encoded body.
    ///
    /// `resultCDR` is therefore the complete response, `[header | status |
    /// result]`, encoded in one pass (`CDREncoder.writeInt8(status)` followed
    /// by the result's `encode(to:)`); a missing header is tolerated. The
    /// status byte in it is replaced with `status`. An empty `resultCDR` (a
    /// goal that ended without a result) yields the minimal frame
    /// `[header | status | pad (3)]`, which the `.rcl` bridge recognizes by
    /// its 8-byte length.
    static func encodeGetResultResponse(status: Int8, resultCDR: Data) -> Data {
        let body = stripInnerEncapsulationHeader(resultCDR)  // [status | result]
        var out = Data(capacity: 4 + max(body.count, 4))
        out.append(cdrHeader)
        out.append(UInt8(bitPattern: status))
        if body.isEmpty {
            out.append(contentsOf: [0, 0, 0])
        } else {
            out.append(body.dropFirst())
        }
        return out
    }

    /// Returns the status and the whole response `[header | status | result]`
    /// (re-based to index 0). Decode it with one `CDRDecoder`: read the
    /// `int8` status, then the result, so the result's fields keep the
    /// alignment origin they were written with.
    static func decodeGetResultResponse(from data: Data) throws -> (status: Int8, resultCDR: Data) {
        guard data.count >= 4 + 1 else { throw ActionFrameDecoderError.payloadTooShort }
        let status = Int8(bitPattern: data[data.startIndex + 4])
        return (status, Data(data))
    }

    // MARK: - FeedbackMessage

    /// Wire shape: `[header (4) | uuid[16] | <bare user feedback body>]`.
    /// `feedbackCDR` may carry the umbrella's encapsulation header; it is stripped.
    /// Like the goal, the feedback starts at body offset 16, so a feedback
    /// encoded from its own origin needs no re-alignment.
    static func encodeFeedbackMessage(goalId: [UInt8], feedbackCDR: Data) -> Data {
        precondition(goalId.count == 16, "goalId must be 16 bytes")
        let feedbackCDR = stripInnerEncapsulationHeader(feedbackCDR)
        var out = Data(capacity: 4 + 16 + feedbackCDR.count)
        out.append(cdrHeader)
        out.append(contentsOf: goalId)
        out.append(feedbackCDR)
        return out
    }

    /// Returns the feedback body with a leading encapsulation header.
    static func decodeFeedbackMessage(from data: Data) throws -> (
        goalId: [UInt8], feedbackCDR: Data
    ) {
        guard data.count >= 4 + 16 else { throw ActionFrameDecoderError.payloadTooShort }
        let goalId = Array(data[(data.startIndex + 4)..<(data.startIndex + 4 + 16)])
        let body = data.suffix(from: data.startIndex + 4 + 16)
        return (goalId, withHeader(Data(body)))
    }

    // MARK: - GoalStatusArray

    /// Wire shape: `[header (4) | count (u32) | GoalStatus * count]`, each
    /// `GoalStatus` being `uuid[16] | sec (i32) | nanosec (u32) | status (i8)`.
    ///
    /// There is no padding after `status`: the next entry starts with the
    /// 1-byte-aligned UUID, and the 3 pad bytes fall before that entry's `sec`
    /// instead. The first entry is therefore 25 bytes and every later one 28
    /// (the UUID of entry `n >= 1` starts at body offset `25 + 28 * (n - 1) + 4`),
    /// so the frame is written and read field by field with `CDRDecoder` /
    /// `CDREncoder` alignment rather than with a fixed stride.
    static func encodeStatusArray(entries: [StatusEntry]) -> Data {
        let encoder = CDREncoder(estimatedSize: 4 + 4 + entries.count * 28)
        encoder.writeEncapsulationHeader()
        encoder.writeUInt32(UInt32(entries.count))
        for e in entries {
            precondition(e.uuid.count == 16, "uuid must be 16 bytes")
            encoder.writeRawBytes(e.uuid)
            encoder.writeInt32(e.stampSec)
            encoder.writeUInt32(e.stampNanosec)
            encoder.writeInt8(e.status)
        }
        return encoder.getData()
    }

    static func decodeStatusArray(from data: Data) throws -> [StatusEntry] {
        guard data.count >= 4 + 4 else { throw ActionFrameDecoderError.payloadTooShort }
        do {
            let decoder = try CDRDecoder(data: Data(data))
            let count = try decoder.readUInt32()
            // Defensive cap mirrors `CDRDecoder.maxSequenceElements` (64 MiB / 25 bytes).
            let maxCount: UInt32 = (64 * 1024 * 1024) / 25
            guard count <= maxCount else { throw ActionFrameDecoderError.invalidCount(count) }
            // Every entry is at least 25 bytes; reject a count the payload cannot hold
            // before reserving storage for it.
            guard Int(count) * 25 <= decoder.remainingBytes else {
                throw ActionFrameDecoderError.payloadTooShort
            }
            var out: [StatusEntry] = []
            out.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                let uuid = [UInt8](try decoder.readRawBytes(count: 16))
                let sec = try decoder.readInt32()
                let nsec = try decoder.readUInt32()
                let status = try decoder.readInt8()
                out.append((uuid: uuid, stampSec: sec, stampNanosec: nsec, status: status))
            }
            return out
        } catch let error as ActionFrameDecoderError {
            throw error
        } catch {
            throw ActionFrameDecoderError.payloadTooShort
        }
    }
}
