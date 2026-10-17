// ZenohPublisherTokenGoldenTests.swift
// MP liveliness tokens captured from rmw_zenoh_cpp on live hosts, read against what
// `ros2 topic info -v` printed for the same publishers.

import Foundation
import XCTest

@testable import SwiftROS2Wire

final class ZenohPublisherTokenGoldenTests: XCTestCase {
    func testHumbleTokens() throws {
        try checkGolden("humble", expectedPublishers: 7)
    }

    func testJazzyTokens() throws {
        try checkGolden("jazzy", expectedPublishers: 7)
    }

    func testLyricalTokens() throws {
        try checkGolden("lyrical", expectedPublishers: 7)
    }

    /// Every token of the fixture is parsed: the `MP` ones must give exactly the `expect`
    /// lines, every other one (services, the node) must be skipped.
    private func checkGolden(
        _ distro: String, expectedPublishers: Int, file: StaticString = #filePath, line: UInt = #line
    )
        throws
    {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "rmw_zenoh_mp_tokens_\(distro)", withExtension: "txt", subdirectory: "Fixtures"),
            file: file, line: line)
        var tokens: [String] = []
        var expected: [ZenohPublisherTokenInfo] = []
        for row in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !row.hasPrefix("#") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "token":
                tokens.append(fields[1])
            case "expect":
                XCTAssertEqual(fields.count, 7, "\(row)", file: file, line: line)
                expected.append(
                    ZenohPublisherTokenInfo(
                        topicName: fields[1], typeName: fields[2],
                        reliability: fields[3] == "reliable" ? .reliable : .bestEffort,
                        durability: fields[4] == "transientLocal" ? .transientLocal : .volatile,
                        nodeName: fields[5], nodeNamespace: fields[6]))
            default:
                XCTFail("unexpected fixture row: \(row)", file: file, line: line)
            }
        }
        XCTAssertEqual(expected.count, expectedPublishers, file: file, line: line)

        let parsed = tokens.compactMap(ZenohWireCodec.parsePublisherToken)
        XCTAssertEqual(parsed.count, tokens.filter { $0.contains("/MP/") }.count, file: file, line: line)
        XCTAssertEqual(
            parsed.sorted { $0.topicName < $1.topicName }, expected.sorted { $0.topicName < $1.topicName },
            file: file, line: line)
    }
}
