import SwiftROS2Messages
import SwiftROS2Transport
import XCTest

@testable import SwiftROS2

final class ParameterServicesTests: XCTestCase {
    private func makeContextAndNode(
        nodeName: String = "talker",
        options: ROS2NodeOptions = .default
    ) async throws -> (ROS2Context, ROS2Node) {
        let mock = MockTransportSession()
        mock.installEchoServiceTransport()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/mock:7447"), session: mock)
        let node = try await ctx.createNode(name: nodeName, options: options)
        return (ctx, node)
    }

    func testStartParameterServicesRegistersAllSixRoutes() async throws {
        let (_, node) = try await makeContextAndNode(
            nodeName: "talker",
            options: ROS2NodeOptions(startParameterServices: false))

        // Manual registration since auto-start is opted out.
        try await node.startParameterServices()

        // One client per service type so the type symbols (and the
        // request/response request hashes) are exercised at compile time —
        // the call-time semantics of each handler are covered by the
        // dedicated per-handler tests below.
        let getCli = try await node.createClient(
            GetParametersSrv.self, name: "/talker/get_parameters")
        try await getCli.waitForService(timeout: .milliseconds(100))

        let setCli = try await node.createClient(
            SetParametersSrv.self, name: "/talker/set_parameters")
        try await setCli.waitForService(timeout: .milliseconds(100))

        let setAtomicCli = try await node.createClient(
            SetParametersAtomicallySrv.self,
            name: "/talker/set_parameters_atomically")
        try await setAtomicCli.waitForService(timeout: .milliseconds(100))

        let listCli = try await node.createClient(
            ListParametersSrv.self, name: "/talker/list_parameters")
        try await listCli.waitForService(timeout: .milliseconds(100))

        let describeCli = try await node.createClient(
            DescribeParametersSrv.self, name: "/talker/describe_parameters")
        try await describeCli.waitForService(timeout: .milliseconds(100))

        let typesCli = try await node.createClient(
            GetParameterTypesSrv.self, name: "/talker/get_parameter_types")
        try await typesCli.waitForService(timeout: .milliseconds(100))
    }

    func testStartParameterServicesIsIdempotent() async throws {
        let (_, node) = try await makeContextAndNode(
            options: ROS2NodeOptions(startParameterServices: false))

        try await node.startParameterServices()
        try await node.startParameterServices()  // second call must be a no-op

        // No exception — and the next createClient still works.
        let cli = try await node.createClient(
            GetParametersSrv.self, name: "/talker/get_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))
    }

    func testGetParametersReturnsDeclaredValues() async throws {
        let (_, node) = try await makeContextAndNode()
        _ = try await node.declareParameter("rate", default: Int64(30))
        _ = try await node.declareParameter("alpha", default: 0.5)
        try await node.startParameterServices()

        let cli = try await node.createClient(
            GetParametersSrv.self, name: "/talker/get_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))

        let resp = try await cli.call(
            GetParametersRequest(names: ["rate", "alpha", "missing"]),
            timeout: .seconds(1))

        XCTAssertEqual(resp.values.count, 3)
        XCTAssertEqual(resp.values[0].type, 2)  // PARAMETER_INTEGER
        XCTAssertEqual(resp.values[0].integerValue, 30)
        XCTAssertEqual(resp.values[1].type, 3)  // PARAMETER_DOUBLE
        XCTAssertEqual(resp.values[1].doubleValue, 0.5)
        XCTAssertEqual(resp.values[2].type, 0)  // PARAMETER_NOT_SET — missing name
    }

    func testSetParametersAcceptsValidWritesAndReportsRangeFailure() async throws {
        let (_, node) = try await makeContextAndNode()
        _ = try await node.declareParameter(
            "rate",
            default: Int64(30),
            descriptor: ROS2ParameterDescriptor(
                name: "rate", type: .integer, integerRange: 1...120))
        _ = try await node.declareParameter("alpha", default: 0.5)
        try await node.startParameterServices()

        let cli = try await node.createClient(
            SetParametersSrv.self, name: "/talker/set_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))

        var goodInt = RclInterfaces.ParameterValue()
        goodInt.type = 2
        goodInt.integerValue = 60
        var badInt = RclInterfaces.ParameterValue()
        badInt.type = 2
        badInt.integerValue = 999  // outside 1...120
        var goodDouble = RclInterfaces.ParameterValue()
        goodDouble.type = 3
        goodDouble.doubleValue = 0.75

        let resp = try await cli.call(
            SetParametersRequest(parameters: [
                Parameter(name: "rate", value: goodInt),
                Parameter(name: "rate", value: badInt),
                Parameter(name: "alpha", value: goodDouble),
                Parameter(name: "missing", value: goodInt),
            ]),
            timeout: .seconds(1))

        XCTAssertEqual(resp.results.count, 4)
        XCTAssertTrue(resp.results[0].successful)
        XCTAssertFalse(resp.results[1].successful)
        XCTAssertTrue(resp.results[2].successful)
        XCTAssertFalse(resp.results[3].successful)  // not declared

        let stored = try await node.getParameter("rate")
        XCTAssertEqual(stored.value, .integer(60))
        let alpha = try await node.getParameter("alpha")
        XCTAssertEqual(alpha.value, .double(0.75))
    }

    func testSetParametersAtomicallyRollsBackOnFailure() async throws {
        let (_, node) = try await makeContextAndNode()
        _ = try await node.declareParameter(
            "rate",
            default: Int64(30),
            descriptor: ROS2ParameterDescriptor(
                name: "rate", type: .integer, integerRange: 1...120))
        _ = try await node.declareParameter("alpha", default: 0.5)
        try await node.startParameterServices()

        let cli = try await node.createClient(
            SetParametersAtomicallySrv.self, name: "/talker/set_parameters_atomically")
        try await cli.waitForService(timeout: .milliseconds(100))

        var goodInt = RclInterfaces.ParameterValue()
        goodInt.type = 2
        goodInt.integerValue = 60
        var goodDouble = RclInterfaces.ParameterValue()
        goodDouble.type = 3
        goodDouble.doubleValue = 0.9
        var badInt = RclInterfaces.ParameterValue()
        badInt.type = 2
        badInt.integerValue = 999

        // First call: every parameter valid → atomic success.
        let okResp = try await cli.call(
            SetParametersAtomicallyRequest(parameters: [
                Parameter(name: "rate", value: goodInt),
                Parameter(name: "alpha", value: goodDouble),
            ]),
            timeout: .seconds(1))
        XCTAssertTrue(okResp.result.successful)
        let rate1 = try await node.getParameter("rate")
        XCTAssertEqual(rate1.value, .integer(60))
        let alpha1 = try await node.getParameter("alpha")
        XCTAssertEqual(alpha1.value, .double(0.9))

        // Second call: second parameter is out-of-range → both rolled back.
        let failResp = try await cli.call(
            SetParametersAtomicallyRequest(parameters: [
                Parameter(name: "alpha", value: goodDouble),
                Parameter(name: "rate", value: badInt),
            ]),
            timeout: .seconds(1))
        XCTAssertFalse(failResp.result.successful)

        // Net effect of failed call must be zero — values match the previous successful call.
        let rate2 = try await node.getParameter("rate")
        XCTAssertEqual(rate2.value, .integer(60))
        let alpha2 = try await node.getParameter("alpha")
        XCTAssertEqual(alpha2.value, .double(0.9))
    }

    func testListParametersReturnsNamesAndPrefixes() async throws {
        let (_, node) = try await makeContextAndNode()
        _ = try await node.declareParameter("rate", default: Int64(30))
        _ = try await node.declareParameter("alpha", default: 0.5)
        _ = try await node.declareParameter("group.beta", default: Int64(1))
        _ = try await node.declareParameter("group.gamma", default: Int64(2))
        try await node.startParameterServices()

        let cli = try await node.createClient(
            ListParametersSrv.self, name: "/talker/list_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))

        // No prefix filter, depth = 0 (recursive).
        let allResp = try await cli.call(
            ListParametersRequest(prefixes: [], depth: 0), timeout: .seconds(1))
        XCTAssertEqual(
            Set(allResp.result.names),
            ["rate", "alpha", "group.beta", "group.gamma"])
        XCTAssertEqual(allResp.result.prefixes, ["group"])

        // Prefix-filtered.
        let groupResp = try await cli.call(
            ListParametersRequest(prefixes: ["group"], depth: 0),
            timeout: .seconds(1))
        XCTAssertEqual(Set(groupResp.result.names), ["group.beta", "group.gamma"])
    }

    func testDescribeParametersReturnsDescriptorsAndMissingFallback() async throws {
        let (_, node) = try await makeContextAndNode()
        _ = try await node.declareParameter(
            "rate",
            default: Int64(30),
            descriptor: ROS2ParameterDescriptor(
                name: "rate", type: .integer, description: "publish rate (Hz)",
                integerRange: 1...120))
        try await node.startParameterServices()

        let cli = try await node.createClient(
            DescribeParametersSrv.self, name: "/talker/describe_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))

        let resp = try await cli.call(
            DescribeParametersRequest(names: ["rate", "missing"]),
            timeout: .seconds(1))
        XCTAssertEqual(resp.descriptors.count, 2)

        XCTAssertEqual(resp.descriptors[0].name, "rate")
        XCTAssertEqual(resp.descriptors[0].type, 2)  // PARAMETER_INTEGER
        XCTAssertEqual(resp.descriptors[0].description, "publish rate (Hz)")
        XCTAssertEqual(resp.descriptors[0].integerRange.count, 1)
        XCTAssertEqual(resp.descriptors[0].integerRange.first?.fromValue, 1)
        XCTAssertEqual(resp.descriptors[0].integerRange.first?.toValue, 120)

        XCTAssertEqual(resp.descriptors[1].name, "missing")
        XCTAssertEqual(resp.descriptors[1].type, 0)  // PARAMETER_NOT_SET
    }

    func testGetParameterTypesReturnsTypesPerName() async throws {
        let (_, node) = try await makeContextAndNode()
        _ = try await node.declareParameter("rate", default: Int64(30))
        _ = try await node.declareParameter("alpha", default: 0.5)
        _ = try await node.declareParameter("flag", default: true)
        try await node.startParameterServices()

        let cli = try await node.createClient(
            GetParameterTypesSrv.self, name: "/talker/get_parameter_types")
        try await cli.waitForService(timeout: .milliseconds(100))

        let resp = try await cli.call(
            GetParameterTypesRequest(names: ["rate", "alpha", "flag", "missing"]),
            timeout: .seconds(1))

        XCTAssertEqual(resp.types, [2, 3, 1, 0])
        // Integer (2), Double (3), Bool (1), NOT_SET (0)
    }

    func testAutoRegistersWhenOptionsDefault() async throws {
        let mock = MockTransportSession()
        mock.installEchoServiceTransport()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/mock:7447"), session: mock)
        // Default options: services should already be registered after createNode.
        let node = try await ctx.createNode(name: "talker")
        _ = try await node.declareParameter("rate", default: Int64(30))

        let cli = try await node.createClient(
            GetParametersSrv.self, name: "/talker/get_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))

        let resp = try await cli.call(
            GetParametersRequest(names: ["rate"]), timeout: .seconds(1))
        XCTAssertEqual(resp.values.first?.integerValue, 30)
    }

    func testSetParametersServiceEmitsEvent() async throws {
        // Phase-4 Task 8: confirm the wire `set_parameters` service routes
        // through the same store path that emits a /parameter_events
        // publication. We need the session handle to inspect publishers,
        // so don't reuse the helper that drops it.
        let mock = MockTransportSession()
        mock.installEchoServiceTransport()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/mock:7447"), session: mock)
        let node = try await ctx.createNode(name: "talker")
        defer {
            Task {
                await node.destroy()
                await ctx.shutdown()
            }
        }
        _ = try await node.declareParameter("rate", default: Int64(30))

        let cli = try await node.createClient(
            SetParametersSrv.self, name: "/talker/set_parameters")
        try await cli.waitForService(timeout: .milliseconds(100))

        var v = RclInterfaces.ParameterValue()
        v.type = 2
        v.integerValue = 99
        _ = try await cli.call(
            SetParametersRequest(parameters: [
                Parameter(name: "rate", value: v)
            ]),
            timeout: .seconds(2)
        )
        // Bounded poll instead of fixed sleep — `dispatchParameterEvent`
        // runs in a detached task and may take longer than 100 ms on a
        // loaded CI runner.
        let deadline = ContinuousClock.now + .seconds(2)
        var pub: MockTransportPublisher?
        while ContinuousClock.now < deadline {
            pub = mock.publishers.first { $0.topic.hasSuffix("/parameter_events") }
            if (pub?.publishedPayloads.count ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(pub)
        // declare emits one, set_parameters emits a second.
        XCTAssertGreaterThanOrEqual(pub?.publishedPayloads.count ?? 0, 2)
    }

    func testOptOutSkipsRegistration() async throws {
        let mock = MockTransportSession()
        mock.installEchoServiceTransport()
        let ctx = try await ROS2Context(
            transport: .zenoh(locator: "tcp/mock:7447"), session: mock)
        let node = try await ctx.createNode(
            name: "talker",
            options: ROS2NodeOptions(startParameterServices: false))
        _ = try await node.declareParameter("rate", default: Int64(30))

        // The mock client dispatcher throws TransportError.notConnected when
        // no matching server exists, which ServiceError.mapping surfaces as
        // .serviceUnavailable. A timeout would also prove the call failed
        // because no service was auto-registered.
        let cli = try await node.createClient(
            GetParametersSrv.self, name: "/talker/get_parameters")
        do {
            _ = try await cli.call(
                GetParametersRequest(names: ["rate"]), timeout: .milliseconds(200))
            XCTFail("expected the call to fail because services were not auto-registered")
        } catch ServiceError.serviceUnavailable {
            // expected: the mock dispatcher could not find a server with the name
        } catch ServiceError.timeout {
            // also acceptable: depending on the mock's failure surface mapping
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
