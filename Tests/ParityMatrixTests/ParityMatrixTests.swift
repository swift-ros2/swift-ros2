import Foundation
import XCTest

@testable import ParityMatrix

final class ParityMatrixTests: XCTestCase {
    private func loadSample() throws -> ParityMatrix {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample-matrix", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ParityMatrix.self, from: data)
    }

    private func decodeMatrix(_ json: String) throws -> ParityMatrix {
        try JSONDecoder().decode(ParityMatrix.self, from: Data(json.utf8))
    }

    func testDecodeSample() throws {
        let matrix = try loadSample()
        XCTAssertEqual(matrix.schemaVersion, 1)
        XCTAssertEqual(matrix.capabilities.count, 2)
        let imu = matrix.capabilities[0]
        XCTAssertEqual(imu.id, "publish.typed.sensor_msgs/Imu")
        XCTAssertEqual(imu.rcl, .supported)
        XCTAssertEqual(imu.verification.correctness.verdict, .pending)
        XCTAssertEqual(matrix.capabilities[1].rcl, .pending)
        XCTAssertNil(matrix.capabilities[1].evidence)
    }

    func testRenderMarkdown() throws {
        let matrix = try loadSample()
        let md = matrix.renderMarkdown()
        XCTAssertTrue(md.hasPrefix("# Parity Matrix"))
        XCTAssertTrue(md.contains("| Capability | pure-Swift | RCL | Severity |"))
        XCTAssertTrue(md.contains("publish.typed.sensor_msgs/Imu"))
        XCTAssertTrue(md.contains("subscribe.serialized.sensor_msgs/Image"))
        // Deterministic: rendering twice yields identical output.
        XCTAssertEqual(md, matrix.renderMarkdown())
    }

    func testValidateRejectsDuplicateIDs() throws {
        var matrix = try loadSample()
        matrix.capabilities.append(matrix.capabilities[0])  // duplicate id
        XCTAssertThrowsError(try matrix.validate()) { error in
            XCTAssertTrue("\(error)".contains("duplicate capability id"))
        }
    }

    func testValidateAcceptsCleanMatrix() throws {
        let matrix = try loadSample()
        XCTAssertNoThrow(try matrix.validate())
    }

    func testCanonicalEncodeIsDeterministicAndRoundTrips() throws {
        // b.cap before a.cap: array order is preserved; .sortedKeys only orders
        // keys *within* each object. evidence carries a slash to prove no escaping.
        let matrix = try decodeMatrix(
            #"""
            {"schemaVersion":1,"capabilities":[
              {"id":"b.cap","apiSymbol":"B","pureSwift":"supported","rcl":"supported",
               "platforms":["macOS"],"typeApplicability":"n-a","severity":"n-a-by-design",
               "verification":{"latency":{"verdict":"pending"},"soak":{"verdict":"pending"},
                 "correctness":{"verdict":"pending"},"resource":{"verdict":"pending"}},
               "evidence":"path/with/slashes.c:10"},
              {"id":"a.cap","apiSymbol":"A","pureSwift":"supported","rcl":"partial",
               "platforms":["iOS"],"typeApplicability":"bundled","severity":"major",
               "verification":{"latency":{"verdict":"pending"},"soak":{"verdict":"pending"},
                 "correctness":{"verdict":"pending"},"resource":{"verdict":"pending"}}}
            ]}
            """#)
        let first = try matrix.encodeCanonicalJSON()
        // Idempotent: decode -> encode reproduces identical bytes.
        let decoded = try JSONDecoder().decode(ParityMatrix.self, from: first)
        let second = try decoded.encodeCanonicalJSON()
        XCTAssertEqual(first, second)
        // Slashes are not escaped, and the file ends in a newline.
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(text.contains("path/with/slashes.c:10"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testSetAxisUpdatesNamedCapabilityOnly() throws {
        var matrix = try decodeMatrix(
            #"""
            {"schemaVersion":1,"capabilities":[
              {"id":"publish.typed.sensor_msgs/Imu","apiSymbol":"p","pureSwift":"supported",
               "rcl":"supported","platforms":["macOS"],"typeApplicability":"bundled",
               "severity":"n-a-by-design",
               "verification":{"latency":{"verdict":"pending"},"soak":{"verdict":"pending"},
                 "correctness":{"verdict":"pending"},"resource":{"verdict":"pending"}}},
              {"id":"param.declare","apiSymbol":"q","pureSwift":"supported",
               "rcl":"supported","platforms":["macOS"],"typeApplicability":"n-a",
               "severity":"n-a-by-design",
               "verification":{"latency":{"verdict":"pending"},"soak":{"verdict":"pending"},
                 "correctness":{"verdict":"pending"},"resource":{"verdict":"pending"}}}
            ]}
            """#)
        try matrix.setAxis(
            capabilityId: "publish.typed.sensor_msgs/Imu", axis: .correctness,
            verdict: .pass, value: "CDR==rmw_serialize")
        // The named capability + axis is updated...
        XCTAssertEqual(matrix.capabilities[0].verification.correctness.verdict, .pass)
        XCTAssertEqual(matrix.capabilities[0].verification.correctness.value, "CDR==rmw_serialize")
        // ...its sibling axis is untouched...
        XCTAssertEqual(matrix.capabilities[0].verification.latency.verdict, .pending)
        // ...and so is every other capability.
        XCTAssertEqual(matrix.capabilities[1].id, "param.declare")
        XCTAssertEqual(matrix.capabilities[1].verification.correctness.verdict, .pending)
        XCTAssertThrowsError(
            try matrix.setAxis(capabilityId: "nope", axis: .latency, verdict: .pass, value: nil))
    }

    func testAxisVerdictNARawValue() throws {
        XCTAssertEqual(AxisVerdict(rawValue: "na"), .na)
        XCTAssertEqual(AxisVerdict.na.rawValue, "na")
    }

    func testSetAxisNARoundTripsThroughCanonicalJSON() throws {
        var matrix = try loadSample()
        try matrix.setAxis(
            capabilityId: "publish.typed.sensor_msgs/Imu", axis: .latency,
            verdict: .na, value: "n/a — represented by corpus")
        let data = try matrix.encodeCanonicalJSON()
        let decoded = try JSONDecoder().decode(ParityMatrix.self, from: data)
        XCTAssertEqual(decoded.capabilities[0].verification.latency.verdict, .na)
        XCTAssertEqual(
            decoded.capabilities[0].verification.latency.value, "n/a — represented by corpus")
    }

    func testRenderShowsNAVerdict() throws {
        var matrix = try loadSample()
        try matrix.setAxis(
            capabilityId: "publish.typed.sensor_msgs/Imu", axis: .resource,
            verdict: .na, value: nil)
        XCTAssertTrue(matrix.renderMarkdown().contains(" na "))
    }
}
