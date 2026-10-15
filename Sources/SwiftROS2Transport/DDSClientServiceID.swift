// DDSClientServiceID.swift
// The `clientid=` USER_DATA entry rmw_cyclonedds_cpp puts on a service
// client's request writer and reply reader.
//
// An rmw_cyclonedds_cpp service server reads the `clientid` of the request
// writer a request came from and, before it writes the reply, waits up to
// 100 ms for its reply writer to match a reader that carries the same
// `clientid`. A client without a `clientid` is answered at once, so a reply
// to a request sent right after discovery can go out before the server's
// reply writer has matched the client's reply reader, and is lost.

import Foundation

package enum DDSClientServiceID {
    /// Byte length of the id (rmw_cyclonedds_cpp's `client_service_id_t`).
    package static let byteCount = 16

    /// A new random id for one service client (or one action client service pair).
    package static func make() -> [UInt8] {
        GIDManager.randomGid()
    }

    /// The id in rmw_cyclonedds_cpp's `csid_to_string` form: hex bytes joined
    /// by dots, the first one zero-padded to two digits.
    package static func string(_ id: [UInt8]) -> String {
        id.enumerated().map { i, b in String(format: i == 0 ? "%02x" : "%x", b) }.joined(separator: ".")
    }

    /// USER_DATA for a client endpoint: `clientid=<id>;` followed by the
    /// `typehash=...;` entry when there is one, in rmw_cyclonedds_cpp's order.
    package static func clientUserData(id: [UInt8], typeHashUserData: String?) -> String {
        "clientid=\(string(id));" + (typeHashUserData ?? "")
    }
}
