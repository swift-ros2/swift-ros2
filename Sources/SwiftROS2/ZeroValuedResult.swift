// ZeroValuedResult.swift
// Builds a zero-valued message by decoding it from an all-zero CDR body.

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages

/// Builds the zero value of a CDR type without knowing its fields.
///
/// `ROS2Action.Result` only promises `CDRCodable`, so the umbrella cannot call
/// a generated `init()`. Decoding the type from an all-zero CDR body gives the
/// same value: every primitive reads 0 (`false` for `bool`), every sequence
/// and string length reads 0 (an empty sequence or string), every fixed-size
/// array reads its elements as zeros, and nested types recurse. That is the
/// rosidl default for every field without an IDL default value.
enum ZeroValuedResult {
    /// The largest all-zero body tried before giving up (fixed-size arrays are
    /// the only fields whose zero value takes more than a few bytes).
    static let maxBodySize = 64 * 1024 * 1024

    static func make<T: CDRDecodable>(_ type: T.Type, distro: ROS2Distro = .jazzy) throws -> T {
        var size = 256
        while true {
            var zeros = Data(count: 4 + size)
            zeros[1] = 0x01  // CDR_LE encapsulation header: 00 01 00 00
            do {
                return try T(from: CDRDecoder(data: zeros, distro: distro))
            } catch CDRDecodingError.unexpectedEndOfData where size < maxBodySize {
                size *= 2
            }
        }
    }
}
