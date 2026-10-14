// ServiceWireFormatTests.swift
// Golden tests for the Service-shaped wire format helpers
// (Zenoh service key expression, SS / SC liveliness tokens, DDS rq / rr
// topic names, and Service request/response DDS type-name conversion).

import XCTest

@testable import SwiftROS2Wire

final class ServiceWireFormatTests: XCTestCase {
    // MARK: - DDS service type names

    func testDDSServiceRequestTypeName() {
        XCTAssertEqual(
            TypeNameConverter.toDDSServiceRequestTypeName("example_interfaces/srv/AddTwoInts"),
            "example_interfaces::srv::dds_::AddTwoInts_Request_"
        )
        XCTAssertEqual(
            TypeNameConverter.toDDSServiceRequestTypeName("std_srvs/srv/Trigger"),
            "std_srvs::srv::dds_::Trigger_Request_"
        )
    }

    func testDDSServiceResponseTypeName() {
        XCTAssertEqual(
            TypeNameConverter.toDDSServiceResponseTypeName("example_interfaces/srv/AddTwoInts"),
            "example_interfaces::srv::dds_::AddTwoInts_Response_"
        )
        XCTAssertEqual(
            TypeNameConverter.toDDSServiceResponseTypeName("std_srvs/srv/Trigger"),
            "std_srvs::srv::dds_::Trigger_Response_"
        )
    }

    // MARK: - Request-typed service key expressions (legacy fallback)

    func testJazzyServiceKeyExpression() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "",
            serviceName: "add_two_ints",
            serviceTypeName: "example_interfaces/srv/AddTwoInts",
            requestTypeHash: "RIHS01_abc123"
        )
        XCTAssertEqual(
            key,
            "0/add_two_ints/example_interfaces::srv::dds_::AddTwoInts_Request_/RIHS01_abc123"
        )
    }

    func testJazzyServiceKeyExpressionWithNamespace() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "/ios",
            serviceName: "trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: "RIHS01_aaa"
        )
        XCTAssertEqual(
            key,
            "0/ios/trigger/std_srvs::srv::dds_::Trigger_Request_/RIHS01_aaa"
        )
    }

    func testHumbleServiceKeyExpression() {
        let codec = ZenohWireCodec(distro: .humble)
        let key = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "",
            serviceName: "add_two_ints",
            serviceTypeName: "example_interfaces/srv/AddTwoInts",
            requestTypeHash: nil
        )
        XCTAssertEqual(
            key,
            "0/add_two_ints/example_interfaces::srv::dds_::AddTwoInts_Request_/TypeHashNotSupported"
        )
    }

    func testJazzyServiceKeyExpressionNoTypeHash() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "",
            serviceName: "add_two_ints",
            serviceTypeName: "example_interfaces/srv/AddTwoInts",
            requestTypeHash: nil
        )
        // Jazzy omits trailing segment when hash is empty (parallel to Pub/Sub).
        XCTAssertEqual(
            key,
            "0/add_two_ints/example_interfaces::srv::dds_::AddTwoInts_Request_"
        )
    }

    func testServiceKeyExpressionStripsLeadingSlashFromServiceName() {
        // Callers may pass either "/trigger" or "trigger" (the umbrella API
        // tends to produce fully-qualified names). The leading slash must be
        // normalized away — otherwise the key expression contains a "//"
        // segment that Zenoh rejects.
        let codec = ZenohWireCodec(distro: .jazzy)
        let withSlash = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "",
            serviceName: "/trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: "RIHS01_aaa"
        )
        let withoutSlash = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "",
            serviceName: "trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: "RIHS01_aaa"
        )
        XCTAssertEqual(withSlash, withoutSlash)
        XCTAssertFalse(withSlash.contains("//"))
        XCTAssertEqual(
            withSlash,
            "0/trigger/std_srvs::srv::dds_::Trigger_Request_/RIHS01_aaa"
        )
    }

    func testServiceKeyExpressionStripsLeadingSlashAndKeepsNamespace() {
        let codec = ZenohWireCodec(distro: .jazzy)
        let key = codec.makeServiceKeyExpr(
            domainId: 0,
            namespace: "/ios",
            serviceName: "/trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            requestTypeHash: "RIHS01_aaa"
        )
        XCTAssertFalse(key.contains("//"))
        XCTAssertEqual(
            key,
            "0/ios/trigger/std_srvs::srv::dds_::Trigger_Request_/RIHS01_aaa"
        )
    }

    // MARK: - Zenoh service key expressions (service type, as rmw_zenoh_cpp)

    /// `std_srvs/srv/Trigger`'s service type hash (rmw_zenoh_cpp keys services with it).
    static let triggerServiceHash = "RIHS01_eeff2cd6fa5ad9d27cdf4dec64818317839b62f212a91e6b5304b634b2062c5f"

    func testServiceKeyUsesServiceTypeAndHashOnHashedDistros() {
        for distro in [ROS2Distro.jazzy, .kilted, .lyrical, .rolling] {
            let key = ZenohWireCodec(distro: distro).makeServiceKeyExpr(
                domainId: 123,
                namespace: "/e2e",
                serviceName: "trigger",
                serviceTypeName: "std_srvs/srv/Trigger",
                serviceTypeHash: Self.triggerServiceHash
            )
            XCTAssertEqual(
                key, "123/e2e/trigger/std_srvs::srv::dds_::Trigger_/\(Self.triggerServiceHash)", "\(distro)")
        }
    }

    func testHumbleServiceKeyUsesServiceTypeAndPlaceholder() {
        let key = ZenohWireCodec(distro: .humble).makeServiceKeyExpr(
            domainId: 123,
            namespace: "/",
            serviceName: "/trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            serviceTypeHash: Self.triggerServiceHash
        )
        XCTAssertEqual(key, "123/trigger/std_srvs::srv::dds_::Trigger_/TypeHashNotSupported")
    }

    func testServiceKeyOmitsMissingHashOnJazzy() {
        let key = ZenohWireCodec(distro: .jazzy).makeServiceKeyExpr(
            domainId: 0,
            namespace: "",
            serviceName: "trigger",
            serviceTypeName: "std_srvs/srv/Trigger",
            serviceTypeHash: nil
        )
        XCTAssertEqual(key, "0/trigger/std_srvs::srv::dds_::Trigger_")
    }

    func testParameterServiceKey() {
        // rcl_interfaces/srv/ListParameters, as a node's automatic
        // `<node>/list_parameters` service announces it on Jazzy+.
        let hash = "RIHS01_3e6062bfbb27bfb8730d4cef2558221f51a11646d78e7bb30a1e83afac3aad9d"
        let key = ZenohWireCodec(distro: .lyrical).makeServiceKeyExpr(
            domainId: 123,
            namespace: "/e2e_srv",
            serviceName: "swift_node/list_parameters",
            serviceTypeName: "rcl_interfaces/srv/ListParameters",
            serviceTypeHash: hash
        )
        XCTAssertEqual(
            key, "123/e2e_srv/swift_node/list_parameters/rcl_interfaces::srv::dds_::ListParameters_/\(hash)")
        let humbleKey = ZenohWireCodec(distro: .humble).makeServiceKeyExpr(
            domainId: 123,
            namespace: "/e2e_srv",
            serviceName: "swift_node/list_parameters",
            serviceTypeName: "rcl_interfaces/srv/ListParameters",
            serviceTypeHash: nil
        )
        XCTAssertEqual(
            humbleKey,
            "123/e2e_srv/swift_node/list_parameters/rcl_interfaces::srv::dds_::ListParameters_/TypeHashNotSupported"
        )
    }

    // MARK: - Zenoh entity liveliness tokens

    func testServiceServerTokenMatchesRmwZenoh() {
        // rmw_zenoh_cpp's layout: enclave `%`, the node namespace and the
        // service name mangled, the service type and its hash.
        let qos = QoSPolicy.servicesDefault
        for distro in [ROS2Distro.jazzy, .kilted, .lyrical, .rolling] {
            let token = ZenohWireCodec(distro: distro).makeEntityLivelinessToken(
                entityKind: "SS",
                domainId: 123,
                sessionId: "aabb",
                nodeId: "7",
                entityId: "9",
                nodeNamespace: "/e2e_srv",
                nodeName: "swift_node",
                name: "/e2e_srv/trigger",
                ddsTypeName: "std_srvs::srv::dds_::Trigger_",
                typeHash: Self.triggerServiceHash,
                qos: qos
            )
            XCTAssertEqual(
                token,
                "@ros2_lv/123/aabb/7/9/SS/%/%e2e_srv/swift_node/%e2e_srv%trigger/std_srvs::srv::dds_::Trigger_/"
                    + "\(Self.triggerServiceHash)/\(qos.toKeyExpr())",
                "\(distro)"
            )
        }
    }

    func testHumbleServiceClientTokenUsesPlaceholder() {
        let qos = QoSPolicy.servicesDefault
        let token = ZenohWireCodec(distro: .humble).makeEntityLivelinessToken(
            entityKind: "SC",
            domainId: 123,
            sessionId: "aabb",
            nodeId: "1",
            entityId: "3",
            nodeNamespace: "/",
            nodeName: "swift_node",
            name: "/trigger",
            ddsTypeName: "std_srvs::srv::dds_::Trigger_",
            typeHash: Self.triggerServiceHash,
            qos: qos
        )
        XCTAssertEqual(
            token,
            "@ros2_lv/123/aabb/1/3/SC/%/%/swift_node/%trigger/std_srvs::srv::dds_::Trigger_/TypeHashNotSupported/"
                + qos.toKeyExpr()
        )
    }

    func testEntityTokenOmitsMissingHashOnJazzy() {
        let qos = QoSPolicy.servicesDefault
        let token = ZenohWireCodec(distro: .jazzy).makeEntityLivelinessToken(
            entityKind: "SS",
            domainId: 0,
            sessionId: "aabb",
            nodeId: "1",
            entityId: "2",
            nodeNamespace: "",
            nodeName: "node",
            name: "trigger",
            ddsTypeName: "std_srvs::srv::dds_::Trigger_",
            typeHash: nil,
            qos: qos
        )
        XCTAssertEqual(
            token, "@ros2_lv/0/aabb/1/2/SS/%/%/node/%trigger/std_srvs::srv::dds_::Trigger_/\(qos.toKeyExpr())")
    }

    func testServiceServerLivelinessQuery() {
        let query = ZenohWireCodec(distro: .lyrical).makeServiceServerLivelinessQuery(
            domainId: 123, name: "/e2e_srv/trigger", ddsTypeName: "std_srvs::srv::dds_::Trigger_")
        XCTAssertEqual(query, "@ros2_lv/123/*/*/*/SS/*/*/*/%e2e_srv%trigger/std_srvs::srv::dds_::Trigger_/**")
    }

    func testServiceEntityKindRawValues() {
        XCTAssertEqual(ZenohWireCodec.ServiceEntityKind.serviceServer.rawValue, "SS")
        XCTAssertEqual(ZenohWireCodec.ServiceEntityKind.serviceClient.rawValue, "SC")
    }

    // MARK: - DDS service topic names

    func testDDSServiceTopicNames() {
        let codec = DDSWireCodec()
        let names = codec.serviceTopicNames(
            serviceName: "/add_two_ints",
            serviceTypeName: "example_interfaces/srv/AddTwoInts"
        )
        XCTAssertEqual(names.requestTopic, "rq/add_two_intsRequest")
        XCTAssertEqual(names.replyTopic, "rr/add_two_intsReply")
        XCTAssertEqual(names.requestTypeName, "example_interfaces::srv::dds_::AddTwoInts_Request_")
        XCTAssertEqual(names.replyTypeName, "example_interfaces::srv::dds_::AddTwoInts_Response_")
    }

    func testDDSServiceTopicNamesNoLeadingSlash() {
        let codec = DDSWireCodec()
        let names = codec.serviceTopicNames(
            serviceName: "trigger",
            serviceTypeName: "std_srvs/srv/Trigger"
        )
        XCTAssertEqual(names.requestTopic, "rq/triggerRequest")
        XCTAssertEqual(names.replyTopic, "rr/triggerReply")
    }

    func testDDSServiceTopicNamesNamespacedService() {
        let codec = DDSWireCodec()
        let names = codec.serviceTopicNames(
            serviceName: "/ios/trigger",
            serviceTypeName: "std_srvs/srv/Trigger"
        )
        XCTAssertEqual(names.requestTopic, "rq/ios/triggerRequest")
        XCTAssertEqual(names.replyTopic, "rr/ios/triggerReply")
    }
}
