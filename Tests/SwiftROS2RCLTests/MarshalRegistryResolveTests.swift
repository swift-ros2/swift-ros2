#if SWIFT_ROS2_RCL
    import CRclBridge
    import XCTest

    /// Registry-expansion guard: every SwiftROS2Messages type whose package
    /// typesupport is bundled in CRos2.xcframework must resolve through
    /// `crcl_marshal_resolve_typesupport`. A resolution miss silently drops
    /// the type to the route-b raw-CDR fallback, so this is the gate that
    /// keeps publish/subscribe fully route-a (rcl + rmw) for the whole set.
    final class MarshalRegistryResolveTests: XCTestCase {
        /// The 13 sensor_msgs types that used the removed typed-publish path;
        /// they now resolve by name like every other entry
        /// (Scripts/regen-rcl-registry.sh).
        static let formerlyTypedTypes: [String] = [
            "sensor_msgs/msg/BatteryState",
            "sensor_msgs/msg/CameraInfo",
            "sensor_msgs/msg/CompressedImage",
            "sensor_msgs/msg/FluidPressure",
            "sensor_msgs/msg/Illuminance",
            "sensor_msgs/msg/Image",
            "sensor_msgs/msg/Imu",
            "sensor_msgs/msg/Joy",
            "sensor_msgs/msg/MagneticField",
            "sensor_msgs/msg/NavSatFix",
            "sensor_msgs/msg/PointCloud2",
            "sensor_msgs/msg/Range",
            "sensor_msgs/msg/Temperature",
        ]

        /// Registry-only entries (REGISTRY_ONLY_TYPES): typesupport resolution
        /// only; publish/subscribe go through the rmw serialized seam.
        static let registryOnlyTypes: [String] = [
            "action_msgs/msg/GoalStatusArray",
            "audio_common_msgs/msg/AudioData",
            "builtin_interfaces/msg/Time",
            "example_interfaces/msg/String",
            "geometry_msgs/msg/Accel",
            "geometry_msgs/msg/Point",
            "geometry_msgs/msg/Point32",
            "geometry_msgs/msg/Pose",
            "geometry_msgs/msg/PoseStamped",
            "geometry_msgs/msg/Quaternion",
            "geometry_msgs/msg/Transform",
            "geometry_msgs/msg/TransformStamped",
            "geometry_msgs/msg/Twist",
            "geometry_msgs/msg/TwistStamped",
            "geometry_msgs/msg/Vector3",
            "geometry_msgs/msg/Vector3Stamped",
            "geometry_msgs/msg/Wrench",
            "point_cloud_interfaces/msg/CompressedPointCloud2",
            "rcl_interfaces/msg/FloatingPointRange",
            "rcl_interfaces/msg/IntegerRange",
            "rcl_interfaces/msg/ListParametersResult",
            "rcl_interfaces/msg/Parameter",
            "rcl_interfaces/msg/ParameterDescriptor",
            "rcl_interfaces/msg/ParameterEvent",
            "rcl_interfaces/msg/ParameterEventDescriptors",
            "rcl_interfaces/msg/ParameterType",
            "rcl_interfaces/msg/ParameterValue",
            "rcl_interfaces/msg/SetParametersResult",
            "sensor_msgs/msg/ChannelFloat32",
            "sensor_msgs/msg/JointState",
            "sensor_msgs/msg/JoyFeedback",
            "sensor_msgs/msg/JoyFeedbackArray",
            "sensor_msgs/msg/LaserEcho",
            "sensor_msgs/msg/LaserScan",
            "sensor_msgs/msg/MultiDOFJointState",
            "sensor_msgs/msg/MultiEchoLaserScan",
            "sensor_msgs/msg/NavSatStatus",
            "sensor_msgs/msg/PointCloud",
            "sensor_msgs/msg/PointField",
            "sensor_msgs/msg/RegionOfInterest",
            "sensor_msgs/msg/RelativeHumidity",
            "sensor_msgs/msg/TimeReference",
            "std_msgs/msg/Bool",
            "std_msgs/msg/Empty",
            "std_msgs/msg/Float64",
            "std_msgs/msg/Header",
            "std_msgs/msg/Int32",
            "std_msgs/msg/String",
            "tf2_msgs/msg/TFMessage",
        ]

        func testEveryFormerlyTypedTypeResolves() {
            for name in Self.formerlyTypedTypes {
                XCTAssertNotNil(
                    crcl_marshal_resolve_typesupport(name),
                    "\(name): entry missing from the typesupport registry")
            }
        }

        func testEveryRegistryOnlyTypeResolves() {
            for name in Self.registryOnlyTypes {
                XCTAssertNotNil(
                    crcl_marshal_resolve_typesupport(name),
                    "\(name): registry-only entry missing from the typesupport registry")
            }
        }

        /// The examples serve example_interfaces/srv/Trigger on RCL
        /// (`srv-server rcl` / `srv-client rcl`), so the service registry must
        /// resolve it next to std_srvs/srv/Trigger.
        func testExampleInterfacesTriggerServiceResolves() {
            for name in ["example_interfaces/srv/Trigger", "std_srvs/srv/Trigger"] {
                XCTAssertNotNil(
                    crcl_srv_registry_lookup(name),
                    "\(name): entry missing from the service typesupport registry")
            }
        }

        /// Types whose packages are NOT bundled in the xcframework must miss
        /// the registry — that miss is what routes them to the route-b
        /// raw-CDR fallback (cyclonedds variant) or the fail-loud gate
        /// (zenoh variant) instead of resolving to garbage.
        func testUnbundledTypesDoNotResolve() {
            for name in [
                "sensor_msgs/msg/DoesNotExist",
                "my_custom_msgs/msg/NotBundled",
            ] {
                XCTAssertNil(
                    crcl_marshal_resolve_typesupport(name),
                    "\(name): unexpectedly present in the typesupport registry")
            }
        }
    }
#endif
