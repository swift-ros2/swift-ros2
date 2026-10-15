// swift-tools-version: 5.9

import Foundation
import PackageDescription

// Apple platforms: pre-built xcframework binaryTargets hosted on
// GitHub Releases. Linux, Windows, and Android: compile the C sources
// directly via SPM, using the matching platform backend inside
// vendor/zenoh-pico. See Scripts/build-xcframework.sh for the macOS
// build helper.
//
// CycloneDDS on Linux resolves through pkg-config; on Apple it ships
// as a prebuilt xcframework. On Windows the DDS path opts in through a
// `CYCLONEDDS_DIR` env var pointing at a vcpkg-installed CycloneDDS
// tree (`vcpkg install cyclonedds:x64-windows`); the manifest then adds
// `-I<dir>/include` and `-L<dir>/lib` to CDDSBridge so `#include
// <dds/dds.h>` and `-lddsc` resolve. Without `CYCLONEDDS_DIR` the
// Windows build keeps the existing Zenoh-only carve-out. Android does
// not ship DDS at all — the DDS family (cCycloneDDS, CDDSBridge,
// SwiftROS2DDS, and the DDS tests) is compiled out via the runtime
// `if canBuildDDS` gate around the targets/products additions further
// down. The SwiftROS2 umbrella itself builds on every platform — its
// dependency on SwiftROS2DDS is conditional on `canBuildDDS` instead.
//
// Cross-compilation target detection. Plain `#if os(...)` at manifest
// scope reflects the HOST, which breaks when cross-compiling from
// Linux to Android (`swift build --swift-sdk <android-triple>`): the
// Linux arm would be selected and the DDS path pulled in. CI exports
// `SWIFT_ROS2_TARGET_OS=android` for the Android matrix so the arm
// selection below matches the intended target. Target-scoped settings
// like `.when(platforms: [.android])` on cSettings stay correct
// regardless because SPM evaluates those against the target platform.
let targetOS: String = {
    // Explicit allow-list so typos or unexpected values fail fast here
    // instead of silently falling through to the Apple arm and quietly
    // re-enabling the DDS path.
    let allowed: Set<String> = ["linux", "windows", "android", "apple"]
    if let raw = Context.environment["SWIFT_ROS2_TARGET_OS"] {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty {
            guard allowed.contains(normalized) else {
                let joined = allowed.sorted().joined(separator: ", ")
                fatalError("SWIFT_ROS2_TARGET_OS must be one of {\(joined)}; got '\(raw)'")
            }
            return normalized
        }
    }
    #if os(Linux)
        return "linux"
    #elseif os(Windows)
        return "windows"
    #elseif os(Android)
        return "android"
    #else
        return "apple"
    #endif
}()

let isLinuxBuild = targetOS == "linux"
let isWindowsBuild = targetOS == "windows"
let isAndroidBuild = targetOS == "android"

// Windows DDS opt-in. When `CYCLONEDDS_DIR` is set on a Windows build,
// the manifest pulls in the DDS family (CCycloneDDS / CDDSBridge /
// SwiftROS2DDS / DDS tests) and wires `-I<dir>/include` + `-L<dir>/lib`
// into CDDSBridge so `#include <dds/dds.h>` and the `-lddsc` link
// emitted by the CCycloneDDS modulemap both resolve against the
// vcpkg-installed CycloneDDS tree. When unset, the Windows arm's
// SwiftROS2 umbrella stays Zenoh-only (its DDS dependency drops out) —
// same shape as 0.5.0 through 0.7.0.
let windowsCycloneDDSDir: String? = {
    guard isWindowsBuild else { return nil }
    guard let raw = Context.environment["CYCLONEDDS_DIR"] else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}()

// Whether the current target can build the CycloneDDS-based DDS path.
// Apple (binary xcframework) and Linux (pkg-config) always can; Windows
// can only when `CYCLONEDDS_DIR` is set; Android never can.
let canBuildDDS = !isAndroidBuild && (!isWindowsBuild || windowsCycloneDDSDir != nil)

let releaseBaseURL = "https://github.com/swift-ros2/swift-ros2/releases/download/2.3.0"

// Native-rcl backend. Apple: in the build graph BY DEFAULT — the prebuilt
// CRos2(.Zenoh) xcframework resolves from the release URL, selected by
// `rclRmwVariant` below (the MZ2 "Replace on Apple" decision: a plain Apple
// `swift build` gets the RCL backend without any env opt-in).
// SWIFT_ROS2_DISABLE_RCL=1 opts an Apple build back out (wire-only graph, no
// xcframework download) — consumers who never use the RCL backend, and the
// CI API-stability gate, which must digest the SAME module graph on both
// sides of the diff (swift-api-digester emits a partial umbrella digest on
// RCL-enabled graphs, misreporting the whole public surface as removed when
// the baseline was built without RCL). Linux: opt-in via
// SWIFT_ROS2_ENABLE_RCL=1 because it consumes a system ROS 2 install (ament
// prefix, see ROS2_RCL_PREFIX below) that a plain build must not demand.
// Windows/Android have no RCL path yet.
let enableRcl =
    (targetOS == "apple" && Context.environment["SWIFT_ROS2_DISABLE_RCL"] != "1")
    || (Context.environment["SWIFT_ROS2_ENABLE_RCL"] == "1" && targetOS == "linux")

// Local-development override: SWIFT_ROS2_RCL_LOCAL=1 resolves the variant
// xcframework from build/ros2*/ (the Scripts/build-ros2-xcframework.sh
// output) instead of the released URL+checksum artifact — used by ci-rcl's
// macOS legs (which build the xcframework from HEAD) and when iterating on
// the ROS 2 cross-build itself.
let useLocalRclXCFramework = Context.environment["SWIFT_ROS2_RCL_LOCAL"] == "1"

// SWIFT_ROS2_RCL_RMW selects the rmw variant baked into the RCL binary
// target: "cyclonedds" (default) -> CRos2.xcframework, or
// "zenoh" -> CRos2Zenoh.xcframework (rmw_zenoh_cpp + fastrtps
// typesupport). They resolve from the release URL as the zips
// CRos2.xcframework.zip / CRos2Zenoh.xcframework.zip — or from
// build/ros2*/ under SWIFT_ROS2_RCL_LOCAL=1 (build with
// `RMW_VARIANT=zenoh Scripts/build-ros2-xcframework.sh`). Both variants
// expose the identical rcl C API, so every Swift target is variant-agnostic.
let rclRmwVariant: String = {
    let raw = Context.environment["SWIFT_ROS2_RCL_RMW"] ?? "cyclonedds"
    guard ["cyclonedds", "zenoh"].contains(raw) else {
        fatalError("SWIFT_ROS2_RCL_RMW must be 'cyclonedds' or 'zenoh'; got '\(raw)'")
    }
    return raw
}()

// On Apple the binary target is NAMED after the variant so the released
// zip's .xcframework basename matches the target name (SwiftPM resolves
// url-based binary artifacts by that match). Linux keeps the single
// CRos2 systemLibrary name for both transports (runtime rmw selection).
// Nothing `import`s this module from Swift, so the name is link-graph-only.
let ros2XCFrameworkName = rclRmwVariant == "zenoh" ? "CRos2Zenoh" : "CRos2"
let ros2CTargetName = isLinuxBuild ? "CRos2" : ros2XCFrameworkName

// Route (B) (Lyrical RCL): an RCL-enabled cyclonedds graph on Apple links the
// CycloneDDS that the RCL xcframework already carries in librclros.a, so the
// wire DDS bridge and rmw_cyclonedds_cpp share one build. Linking the wire
// CCycloneDDS next to it puts two CycloneDDS builds into one binary, which
// aborts at node creation.
let ddsFromRclXCFramework =
    enableRcl && targetOS == "apple" && rclRmwVariant == "cyclonedds"

// zenoh-pico (the wire path) and zenoh-c (bundled inside CRos2Zenoh)
// both export the standard zenoh C API, so they cannot link into one binary.
// Selecting the zenoh rmw variant therefore carves the zenoh-pico wire family
// (CZenohPico / CZenohBridge / SwiftROS2Zenoh + its tests) out of the build
// graph; the umbrella's wire `.zenoh` arm compiles out via
// `#if canImport(SwiftROS2Zenoh)`, and `.zenoh` resolves to rcl +
// rmw_zenoh_cpp instead (the SWIFT_ROS2_RCL_RMW_ZENOH arm of
// ROS2Context.makeDefaultSession).
let dropZenohWire = enableRcl && rclRmwVariant == "zenoh"

// Linux consumes system ROS 2 via a COLON-SEPARATED, ament-overlay-style prefix
// list (ROS2_RCL_PREFIX, e.g. "$HOME/ros2_ws/install:/opt/ros/jazzy"; overlay
// first, base distro last). When unset it defaults to a single
// /opt/ros/${ROS_DISTRO:-jazzy}. rcl is an ament/CMake package with NO
// pkg-config, so — like the Windows CYCLONEDDS_DIR path — the manifest injects
// -I/-L/-l flags itself rather than deferring to pkg-config. Each ROS 2 package
// installs its headers under an isolated include/<pkg>/ dir, so add one -I per
// include subdir present in every prefix. The -l set is kept in lockstep with
// Scripts/build-linux-rcl-deps.sh's REQUIRED_LIBS (the single source of truth
// for "which ROS 2 libs must resolve").
let rclLinuxPrefixes: [String] = {
    let raw =
        Context.environment["ROS2_RCL_PREFIX"].flatMap { $0.isEmpty ? nil : $0 }
        ?? "/opt/ros/\(Context.environment["ROS_DISTRO"] ?? "jazzy")"
    return raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
}()
let rclLinuxIncludeFlags: [String] = {
    guard enableRcl && isLinuxBuild else { return [] }
    var flags: [String] = []
    for prefix in rclLinuxPrefixes {
        let inc = "\(prefix)/include"
        flags.append("-I\(inc)")
        let subdirs = (try? FileManager.default.contentsOfDirectory(atPath: inc)) ?? []
        for d in subdirs.sorted() where !d.hasPrefix(".") {
            flags.append("-I\(inc)/\(d)")
        }
    }
    return flags
}()
let rclLinuxLinkerFlags: [String] = {
    guard enableRcl && isLinuxBuild else { return [] }
    // rcl stack + per-package typesupport. Kept identical to
    // Scripts/build-linux-rcl-deps.sh REQUIRED_LIBS (the presence check).
    let typesupportLibs = [
        "rcl", "rmw", "rmw_implementation", "rcutils", "rcl_action",
        "rosidl_runtime_c", "rosidl_typesupport_c", "rosidl_typesupport_introspection_c",
        "action_msgs__rosidl_typesupport_c", "geometry_msgs__rosidl_typesupport_c",
        "sensor_msgs__rosidl_typesupport_c", "std_msgs__rosidl_typesupport_c",
        "std_srvs__rosidl_typesupport_c", "tf2_msgs__rosidl_typesupport_c",
        "builtin_interfaces__rosidl_typesupport_c", "rcl_interfaces__rosidl_typesupport_c",
        "example_interfaces__rosidl_typesupport_c", "audio_common_msgs__rosidl_typesupport_c",
        "point_cloud_interfaces__rosidl_typesupport_c",
    ]
    // Each <pkg>__rosidl_typesupport_c.so carries only a DT_NEEDED on its
    // sibling <pkg>__rosidl_generator_c.so, which defines the message/srv
    // __create/__init/__destroy functions the marshal + srv/action registries
    // call directly. Modern linkers default to --no-copy-dt-needed-entries, so
    // an indirectly-NEEDED library is not used to resolve references from our
    // own objects, and ld.gold (this toolchain's linker) rejects
    // --copy-dt-needed-entries outright — so the generator_c libs must be named
    // explicitly. (On Apple the single merged xcframework archive sidesteps
    // this: every symbol is already inside one .a.)
    let generatorLibs = [
        "action_msgs", "geometry_msgs", "sensor_msgs", "std_msgs", "std_srvs",
        "tf2_msgs", "builtin_interfaces", "rcl_interfaces", "example_interfaces",
        "audio_common_msgs", "point_cloud_interfaces",
    ].map { "\($0)__rosidl_generator_c" }
    // The ROS libs live outside the default loader path, so carry an rpath per
    // prefix for the final executable link. SPM forwards linker unsafeFlags
    // verbatim to the compiler driver, which understands -L/-l directly but not
    // the `-Wl,` passthrough — so express rpath with the `-Xlinker` idiom.
    var flags: [String] = []
    for prefix in rclLinuxPrefixes {
        flags.append("-L\(prefix)/lib")
        flags.append(contentsOf: ["-Xlinker", "-rpath", "-Xlinker", "\(prefix)/lib"])
    }
    flags.append(contentsOf: (typesupportLibs + generatorLibs).map { "-l\($0)" })
    // C++ runtime. libswiftCore.so (which the SPM link driver pulls into every
    // executable, even the C-only rcl-smoke / crcl-smoke) has a DT_NEEDED on
    // libstdc++.so.6, and the dlopen'd rmw C++ impl needs it at runtime.
    // `-lstdc++` requires a libstdc++.so dev symlink that clang's selected GCC
    // dir does not provide on this toolchain (only libstdc++.so.6 ships), so
    // link the versioned runtime by exact filename — it resolves from the
    // standard multiarch dir regardless of which GCC clang selects.
    flags.append("-l:libstdc++.so.6")
    return flags
}()
// Swift targets that `import CRclBridge` (directly, or transitively via
// SwiftROS2RCL / the SwiftROS2 umbrella) must build the CRclBridge Clang
// module, whose PUBLIC headers `#include <rcl/...>` / <rosidl_runtime_c/...>.
// C-target cSettings do not propagate to that module build (on Apple the
// xcframework's header path does the job; the Linux systemLibrary has no
// pkg-config to propagate absolute paths), so forward the same include set as
// `-Xcc -I` on those Swift targets.
let rclLinuxSwiftSettings: [SwiftSetting] =
    (enableRcl && isLinuxBuild)
    ? [.unsafeFlags(rclLinuxIncludeFlags.flatMap { ["-Xcc", $0] })]
    : []

// Non-unix zenoh-pico platform backends shared between the Linux and
// Android arms — both use the unix backend inside `src/system/unix`.
let zenohPicoNonUnixBackends = [
    "CMakeLists.txt", "README.md", "LICENSE", "tests", "examples", "docs", "ci",
    "src/system/arduino",
    "src/system/emscripten",
    "src/system/espidf",
    "src/system/flipper",
    "src/system/freertos",
    "src/system/mbed",
    "src/system/rpi_pico",
    "src/system/threadx",
    "src/system/windows",
    "src/system/zephyr",
]

// Local-development override: SWIFT_ROS2_ZENOH_LOCAL=1 resolves CZenohPico from
// build/zenoh-pico/ (the `Scripts/build-xcframework.sh zenoh-pico build/zenoh-pico`
// output) instead of the released URL+checksum artifact, so a zenoh-pico change
// can be tested on Apple before it is released.
let useLocalZenohXCFramework = Context.environment["SWIFT_ROS2_ZENOH_LOCAL"] == "1"

let cZenohPico: Target = {
    if isLinuxBuild || isAndroidBuild {
        return .target(
            name: "CZenohPico",
            path: "vendor/zenoh-pico",
            exclude: zenohPicoNonUnixBackends,
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("Z_FEATURE_LINK_TCP", to: "1"),
                .define("Z_FEATURE_LIVELINESS", to: "1"),
                // Target-platform conditional — SPM evaluates against the
                // actual target triple, so this picks up ZENOH_ANDROID on
                // Android cross-builds even though the Linux host drove
                // the `isLinuxBuild || isAndroidBuild` arm selection.
                .define("ZENOH_LINUX", to: "1", .when(platforms: [.linux])),
                .define("ZENOH_ANDROID", to: "1", .when(platforms: [.android])),
            ]
        )
    } else if isWindowsBuild {
        return .target(
            name: "CZenohPico",
            path: "vendor/zenoh-pico",
            exclude: [
                "CMakeLists.txt", "README.md", "LICENSE", "tests", "examples", "docs", "ci",
                "src/system/arduino",
                "src/system/emscripten",
                "src/system/espidf",
                "src/system/flipper",
                "src/system/freertos",
                "src/system/mbed",
                "src/system/rpi_pico",
                "src/system/threadx",
                "src/system/unix",
                "src/system/zephyr",
            ],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("Z_FEATURE_LINK_TCP", to: "1"),
                .define("Z_FEATURE_LIVELINESS", to: "1"),
                .define("ZENOH_WINDOWS", to: "1"),
            ]
        )
    } else if useLocalZenohXCFramework {
        return .binaryTarget(
            name: "CZenohPico",
            path: "build/zenoh-pico/CZenohPico.xcframework"
        )
    } else {
        // Apple: binary xcframework.
        return .binaryTarget(
            name: "CZenohPico",
            url: "\(releaseBaseURL)/CZenohPico.xcframework.zip",
            checksum: "dd505ba148c089c59fc353c554e84b57518c6c409172d8f239e3b5372a22965a"
        )
    }
}()

/// A product of swift-ros2-rosidl (CDR, protocols, runtime interfaces).
func rosidl(_ name: String) -> Target.Dependency {
    .product(name: name, package: "swift-ros2-rosidl")
}

// Products and targets common to every supported platform (the Zenoh
// path and the pure-Swift layers).
var products: [Product] = [
    .library(name: "SwiftROS2Wire", targets: ["SwiftROS2Wire"]),
    .library(name: "SwiftROS2Transport", targets: ["SwiftROS2Transport"]),
]

var targets: [Target] = [
    // Wire format codecs (ROS2Distro comes from rosidl's SwiftROS2Messages)
    .target(
        name: "SwiftROS2Wire",
        dependencies: [rosidl("SwiftROS2Messages")],
        path: "Sources/SwiftROS2Wire"
    ),

    // Transport abstraction layer
    .target(
        name: "SwiftROS2Transport",
        dependencies: [rosidl("SwiftROS2CDR"), "SwiftROS2Wire"],
        path: "Sources/SwiftROS2Transport"
    ),

    // Pure-Swift and Zenoh-path tests (available on every platform)
    .testTarget(
        name: "SwiftROS2WireTests",
        dependencies: ["SwiftROS2Wire"],
        path: "Tests/SwiftROS2WireTests"
    ),
    .testTarget(
        name: "SwiftROS2TransportTests",
        dependencies: ["SwiftROS2Transport", "SwiftROS2Wire", "SwiftROS2TestSupport"],
        path: "Tests/SwiftROS2TransportTests"
    ),

    // Parity matrix model + renderer (pure Swift, all platforms).
    .target(
        name: "ParityMatrix",
        dependencies: [],
        path: "Sources/ParityMatrix"
    ),

    .executableTarget(
        name: "parity-tool",
        dependencies: [
            "ParityMatrix",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "Sources/parity-tool"
    ),

    // Internal tool (not a product): regenerates CRclBridge's name-keyed
    // type-support registries from type-name lists
    // (Scripts/regen-rcl-registry.sh).
    .executableTarget(
        name: "rcl-registry-gen",
        dependencies: [rosidl("SwiftROS2Gen"), .product(name: "ArgumentParser", package: "swift-argument-parser")],
        path: "Sources/rcl-registry-gen"
    ),

    .testTarget(
        name: "ParityMatrixTests",
        dependencies: ["ParityMatrix"],
        path: "Tests/ParityMatrixTests",
        // Copy the file itself: `.copy("Resources")` would nest it one directory deeper under the
        // swift-build bundle layout, where `Bundle.module.url(forResource:)` no longer finds it.
        resources: [.copy("Resources/sample-matrix.json")]
    ),

    // Internal benchmark / soak-analysis target — not exported as a product.
    // Depends on SwiftROS2Zenoh whenever the wire family is in the graph so
    // `canImport(SwiftROS2Zenoh)` inside HarnessCLI.zenohStack agrees with the
    // umbrella's own conditional dep (line ~501) and with the test target —
    // otherwise the RESULT-line stack stamp reads "rcl-rmw_zenoh" on the wire path.
    // The SWIFT_ROS2_RCL define mirrors makeDefaultSession's Linux runtime-rmw
    // arm, where `.zenoh` routes to rcl + rmw_zenoh_cpp even though the wire
    // family stays linked (MZ5) — without it the stack stamp lies on Linux.
    .target(
        name: "SwiftROS2Bench",
        dependencies: dropZenohWire ? [] : ["SwiftROS2Zenoh"],
        path: "Sources/SwiftROS2Bench",
        swiftSettings: enableRcl ? [.define("SWIFT_ROS2_RCL")] : []
    ),
    .testTarget(
        name: "SwiftROS2BenchTests",
        dependencies: ["SwiftROS2Bench"],
        path: "Tests/SwiftROS2BenchTests",
        swiftSettings: enableRcl ? [.define("SWIFT_ROS2_RCL")] : []
    ),
]

// zenoh-pico wire family — every platform EXCEPT the zenoh-rmw RCL variant
// (symbol collision with zenoh-c; see `dropZenohWire` above).
if !dropZenohWire {
    targets.append(contentsOf: [
        // Native C FFI for zenoh-pico. Apple platforms receive the pre-built
        // xcframework; Linux, Windows, and Android compile from source using
        // the matching platform backend inside vendor/zenoh-pico.
        cZenohPico,

        // C bridge for zenoh-pico (Conduit-authored FFI shim).
        .target(
            name: "CZenohBridge",
            dependencies: ["CZenohPico"],
            path: "Sources/CZenohBridge",
            sources: ["zenoh_bridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define(
                    "ZENOH_MACOS", to: "1",
                    .when(platforms: [.macOS, .macCatalyst, .iOS, .visionOS])),
                .define("ZENOH_LINUX", to: "1", .when(platforms: [.linux])),
                .define("ZENOH_WINDOWS", to: "1", .when(platforms: [.windows])),
                .define("ZENOH_ANDROID", to: "1", .when(platforms: [.android])),
                .define("Z_FEATURE_LINK_TCP", to: "1"),
                .define("Z_FEATURE_LIVELINESS", to: "1"),
            ],
            linkerSettings: [
                .linkedLibrary("Ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("Iphlpapi", .when(platforms: [.windows])),
            ]
        ),

        // Internal wire fallback — not a product since 2.0.0.
        // Swift-facing Zenoh module — hosts ZenohClient, the default
        // implementation of ZenohClientProtocol defined in SwiftROS2Transport.
        .target(
            name: "SwiftROS2Zenoh",
            dependencies: ["CZenohBridge", "SwiftROS2Transport", "SwiftROS2Wire"],
            path: "Sources/SwiftROS2Zenoh"
        ),
        .testTarget(
            name: "SwiftROS2ZenohTests",
            dependencies: ["SwiftROS2Zenoh"],
            path: "Tests/SwiftROS2ZenohTests"
        ),
    ])
}

// DDS family — CCycloneDDS, CDDSBridge, SwiftROS2DDS, and the DDS tests.
// Only included on platforms where CycloneDDS is consumable (see
// `canBuildDDS` above): Apple via binary xcframework, Linux via
// pkg-config, Windows via vcpkg + `CYCLONEDDS_DIR`. RCL-enabled cyclonedds
// graphs on Apple (`ddsFromRclXCFramework`) take CycloneDDS from `CRos2`
// instead and declare no `CCycloneDDS` (route B).
// Android does not ship DDS. Where this is absent, the SwiftROS2 umbrella
// below drops its SwiftROS2DDS dependency and `.dds` fails loudly at runtime.
if canBuildDDS {
    let cCycloneDDS: Target = {
        if isLinuxBuild {
            return .systemLibrary(
                name: "CCycloneDDS",
                path: "Sources/CCycloneDDS",
                pkgConfig: "CycloneDDS"
            )
        } else if isWindowsBuild {
            // Windows uses the same modulemap + shim.h as Linux, but
            // header / library search paths come from `CYCLONEDDS_DIR`
            // (vcpkg) injected onto CDDSBridge below — there is no
            // pkg-config in the picture.
            return .systemLibrary(
                name: "CCycloneDDS",
                path: "Sources/CCycloneDDS"
            )
        } else {
            return .binaryTarget(
                name: "CCycloneDDS",
                url: "\(releaseBaseURL)/CCycloneDDS.xcframework.zip",
                checksum: "ff4af2fd71fd8e4467a93190401fdad91be5866f2f076c9c44d0324db40eb3a6"
            )
        }
    }()

    // CDDSBridge consumes `<dds/...>` headers via `#include` and links
    // `ddsc`. On Linux those flags come from pkg-config; on Apple they
    // come from the xcframework. On Windows the manifest threads
    // `-I<vcpkg>/include` + `-L<vcpkg>/lib` through `cSettings` /
    // `linkerSettings` keyed off `CYCLONEDDS_DIR`, plus an explicit
    // `.linkedLibrary("ddsc")` (the modulemap's `link "ddsc"` directive
    // only fires when something does `import CCycloneDDS` from Swift,
    // and nobody in this package does — CDDSBridge reaches CycloneDDS
    // through plain `#include`). The unsafeFlags are gated on
    // `isWindowsBuild` at manifest scope so non-Windows targets see no
    // unsafe flags — that keeps the package consumable as an external
    // SPM dependency on Apple/Linux.
    var ddsBridgeCSettings: [CSetting] = [.define("DDS_AVAILABLE", to: "1")]
    var ddsBridgeLinkerSettings: [LinkerSetting] = []
    if isWindowsBuild, let dir = windowsCycloneDDSDir {
        // Forward-slash the path so clang on Windows sees uniform
        // separators regardless of how `CYCLONEDDS_DIR` was exported.
        let normalizedDir = dir.replacingOccurrences(of: "\\", with: "/")
        ddsBridgeCSettings.append(.unsafeFlags(["-I\(normalizedDir)/include"]))
        // CycloneDDS's `dds/ddsrt/misc.h` defines `DDSRT_WARNING_MSVC_OFF(x)`
        // as `__pragma(warning(disable: ## x))`. The `##` token-paste
        // glues `:` and the warning number into `:4146`, which MSVC
        // accepts but clang rejects with `error: pasting formed ':4146',
        // an invalid preprocessing token [-Winvalid-token-paste]`.
        // Swift on Windows ships clang.exe, so the headers refuse to
        // parse without this suppression.
        ddsBridgeCSettings.append(.unsafeFlags(["-Wno-invalid-token-paste"]))
        ddsBridgeLinkerSettings.append(.unsafeFlags(["-L\(normalizedDir)/lib"]))
        ddsBridgeLinkerSettings.append(.linkedLibrary("ddsc"))
    }

    if !ddsFromRclXCFramework {
        targets.append(cCycloneDDS)
    }
    let ddsBridgeDependency: Target.Dependency =
        ddsFromRclXCFramework ? .byName(name: ros2XCFrameworkName) : "CCycloneDDS"

    targets.append(contentsOf: [
        .target(
            name: "CDDSBridge",
            dependencies: [ddsBridgeDependency],
            path: "Sources/CDDSBridge",
            sources: ["dds_bridge.c", "raw_cdr_sertype.c"],
            publicHeadersPath: "include",
            cSettings: ddsBridgeCSettings,
            linkerSettings: ddsBridgeLinkerSettings
        ),

        // Internal wire fallback — not a product since 2.0.0.
        .target(
            name: "SwiftROS2DDS",
            dependencies: ["CDDSBridge", "SwiftROS2Transport", "SwiftROS2Wire"],
            path: "Sources/SwiftROS2DDS"
        ),

        .testTarget(
            name: "SwiftROS2DDSTests",
            dependencies: ["SwiftROS2DDS", "SwiftROS2Transport", "CDDSBridge", "SwiftROS2TestSupport"],
            path: "Tests/SwiftROS2DDSTests"
        ),
    ])
}

// SwiftROS2 umbrella + examples + umbrella-level tests — every platform.
// Backends are conditional dependencies: SwiftROS2DDS where CycloneDDS is
// consumable (`canBuildDDS`), SwiftROS2Zenoh unless the zenoh-rmw RCL variant
// carved the wire family out (`dropZenohWire`). Context.swift mirrors both
// with `#if canImport(...)`. Android and DDS-less Windows therefore get a
// Zenoh-only umbrella; `.dds` throws `unsupportedFeature` there.
products.append(.library(name: "SwiftROS2", targets: ["SwiftROS2"]))

var swiftROS2Deps: [Target.Dependency] = [
    rosidl("SwiftROS2CDR"), rosidl("SwiftROS2Messages"), rosidl("BuiltinInterfaces"),
    rosidl("UniqueIdentifierMsgs"), rosidl("ActionMsgs"), rosidl("RclInterfaces"),
    "SwiftROS2Transport", "SwiftROS2Wire",
]
if canBuildDDS {
    swiftROS2Deps.append("SwiftROS2DDS")
}
if !dropZenohWire {
    swiftROS2Deps.append("SwiftROS2Zenoh")
}
var swiftROS2SwiftSettings: [SwiftSetting] = []
if enableRcl {
    swiftROS2Deps.append("SwiftROS2RCL")
    swiftROS2SwiftSettings.append(.define("SWIFT_ROS2_RCL"))
    if rclRmwVariant == "zenoh" {
        swiftROS2SwiftSettings.append(.define("SWIFT_ROS2_RCL_RMW_ZENOH"))
    }
}

var swiftROS2TestsSwiftSettings: [SwiftSetting] = []
if enableRcl {
    swiftROS2TestsSwiftSettings.append(.define("SWIFT_ROS2_RCL"))
    if rclRmwVariant == "zenoh" {
        swiftROS2TestsSwiftSettings.append(.define("SWIFT_ROS2_RCL_RMW_ZENOH"))
    }
}

var integrationDeps: [Target.Dependency] = [
    "SwiftROS2", rosidl("SwiftROS2Messages"), "SwiftROS2Transport", "SwiftROS2ExampleInterfaces",
    "SwiftROS2TestFixtures", "SwiftROS2TestSupport",
]
var integrationSwiftSettings: [SwiftSetting] = []
if enableRcl {
    integrationDeps.append("SwiftROS2RCL")
    integrationSwiftSettings.append(.define("SWIFT_ROS2_RCL"))
}

targets.append(contentsOf: [
    // Internal generated targets (not products): example_interfaces for the examples,
    // and std/geometry/sensor/tf2/audio_common fixtures for the tests.
    // Regenerate with Scripts/regenerate-internal-types.sh.
    .target(
        name: "SwiftROS2ExampleInterfaces",
        dependencies: [
            rosidl("SwiftROS2CDR"), rosidl("SwiftROS2Messages"), rosidl("BuiltinInterfaces"),
            rosidl("UniqueIdentifierMsgs"),
        ],
        path: "Sources/SwiftROS2ExampleInterfaces"
    ),
    // Shared test helpers (polling waits, a sendable box); a dependency of the test targets only.
    .target(
        name: "SwiftROS2TestSupport",
        path: "Tests/SwiftROS2TestSupport"
    ),
    .target(
        name: "SwiftROS2TestFixtures",
        dependencies: [
            rosidl("SwiftROS2CDR"), rosidl("SwiftROS2Messages"), rosidl("BuiltinInterfaces"),
            rosidl("UniqueIdentifierMsgs"),
        ],
        path: "Sources/SwiftROS2TestFixtures"
    ),
    .target(
        name: "SwiftROS2",
        dependencies: swiftROS2Deps,
        path: "Sources/SwiftROS2",
        swiftSettings: swiftROS2SwiftSettings
    ),

    // Example executables — minimal example_interfaces/msg/String talker + listener
    // demos in the shape of demo_nodes_cpp. Transport (zenoh or dds) is
    // picked by the first CLI argument so one binary covers both.
    .executableTarget(
        name: "talker",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/Talker"
    ),
    .executableTarget(
        name: "listener",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/Listener"
    ),
    .executableTarget(
        name: "latched-talker",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/LatchedTalker"
    ),
    .executableTarget(
        name: "srv-server",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/SrvServer"
    ),
    .executableTarget(
        name: "srv-client",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/SrvClient"
    ),
    .executableTarget(
        name: "action-server",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/ActionServer"
    ),
    .executableTarget(
        name: "action-client",
        dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
        path: "Sources/Examples/ActionClient"
    ),
    .executableTarget(
        name: "parameter-demo",
        dependencies: ["SwiftROS2"],
        path: "Sources/Examples/ParameterDemo"
    ),

    .testTarget(
        name: "SwiftROS2Tests",
        dependencies: [
            "SwiftROS2", rosidl("SwiftROS2Messages"), rosidl("SwiftROS2CDR"), "SwiftROS2ExampleInterfaces",
            "SwiftROS2TestFixtures", "SwiftROS2TestSupport",
        ],
        path: "Tests/SwiftROS2Tests",
        swiftSettings: swiftROS2TestsSwiftSettings
    ),
    .testTarget(
        name: "SwiftROS2IntegrationTests",
        dependencies: integrationDeps,
        path: "Tests/SwiftROS2IntegrationTests",
        swiftSettings: integrationSwiftSettings
    ),
])

// Native-rcl backend family, gated by `enableRcl`: on by default on Apple
// (SWIFT_ROS2_DISABLE_RCL=1 opts out), opt-in via SWIFT_ROS2_ENABLE_RCL=1 on
// Linux (see the `enableRcl` block comment near the top of this manifest).
//
if enableRcl {
    // Apple: prebuilt merged xcframework. Linux: the system ROS 2 install
    // (ament prefix). rcl has no pkg-config, so — unlike CCycloneDDS on Linux —
    // no `pkgConfig:` is passed; the -I/-L/-l come from the CRclBridge cSettings
    // + the per-target linker flags below (the same shape as the Windows
    // CCycloneDDS systemLibrary path). Nothing `import`s the CRos2 module
    // from Swift, so on Linux the systemLibrary's shim.h/modulemap is
    // declared-but-never-compiled — CRclBridge reaches rcl through plain
    // `#include` resolved by its own -I flags.
    if isLinuxBuild {
        targets.append(
            .systemLibrary(name: "CRos2", path: "Sources/CRos2"))
    } else if useLocalRclXCFramework {
        // Local xcframework built by Scripts/build-ros2-xcframework.sh — the
        // ci-rcl macOS legs and ROS-2-cross-build development use this.
        targets.append(
            .binaryTarget(
                name: ros2XCFrameworkName,
                path: rclRmwVariant == "zenoh"
                    ? "build/ros2zenoh/CRos2Zenoh.xcframework"
                    : "build/ros2/CRos2.xcframework"
            ))
    } else if rclRmwVariant == "zenoh" {
        targets.append(
            .binaryTarget(
                name: "CRos2Zenoh",
                url: "\(releaseBaseURL)/CRos2Zenoh.xcframework.zip",
                checksum: "0c1c97a9cc59ea908411fecfbd4e20a34fee505b63a17717a8e3592dbea6fd05"
            ))
    } else {
        targets.append(
            .binaryTarget(
                name: "CRos2",
                url: "\(releaseBaseURL)/CRos2.xcframework.zip",
                checksum: "cfa9aa335720ea2515ab2717d324a739841f81a5101187949811f82c5805d51e"
            ))
    }
    // rmw_cyclonedds_cpp / rcpputils in CRos2 are C++, so every target
    // that links the merged archive needs the C++ runtime. On Apple that is
    // libc++ (`-lc++`); on Linux the system ROS 2 libs are built against
    // libstdc++ (linked via `-l:libstdc++.so.6` inside rclLinuxLinkerFlags),
    // and the ament prefix -L/-l/-rpath flags ride along so the final
    // executable link resolves rcl and friends. Every RCL executable/test below
    // therefore uses `isLinuxBuild ? rclLinuxLinkAll : <Apple settings>`. The
    // Apple zenoh variant additionally bundles zenoh-c's Rust staticlib, whose
    // rustls/ring TLS, network monitoring, and serialport (transport_serial
    // feature) code require these system frameworks at final link.
    let rclLinuxLinkAll: [LinkerSetting] = [.unsafeFlags(rclLinuxLinkerFlags)]
    // Applied to CRclBridge AND to targets that depend on CRos2 directly
    // (rcl-smoke).
    let rclBridgeLinkerSettings: [LinkerSetting] =
        isLinuxBuild
        ? rclLinuxLinkAll
        : (rclRmwVariant == "zenoh"
            ? [
                .linkedLibrary("c++"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
            : [.linkedLibrary("c++")])
    targets.append(
        .executableTarget(
            name: "rcl-smoke",
            dependencies: [.target(name: ros2CTargetName)],
            path: "Sources/Examples/RclSmoke",
            // C source that `#include <rcl/rcl.h>` directly; cSettings do not
            // propagate from CRos2 (no pkg-config), so inject -I here too.
            cSettings: isLinuxBuild ? [.unsafeFlags(rclLinuxIncludeFlags)] : [],
            linkerSettings: rclBridgeLinkerSettings
        ))
    targets.append(
        .target(
            name: "CRclBridge",
            dependencies: [.target(name: ros2CTargetName)],
            path: "Sources/CRclBridge",
            sources: [
                "rcl_bridge.c", "rcl_subscription.c", "rcl_service.c", "rcl_client.c",
                "rcl_action_server.c", "rcl_action_client.c", "crcl_zeroing_allocator.c", "Generated",
            ],
            publicHeadersPath: "include",
            // On Linux the rcl / rmw / rosidl headers CRclBridge `#include`s
            // resolve from the ament prefix via these -I flags (no pkg-config
            // for rcl). On Apple the xcframework supplies them, so no cSettings.
            cSettings: isLinuxBuild ? [.unsafeFlags(rclLinuxIncludeFlags)] : [],
            linkerSettings: rclBridgeLinkerSettings
        ))
    targets.append(
        .executableTarget(
            name: "crcl-smoke",
            dependencies: ["CRclBridge"],
            path: "Sources/Examples/CrclSmoke",
            // C source that `#include "rcl_bridge.h"` (which transitively pulls
            // rosidl headers); cSettings do not propagate from CRclBridge, so
            // inject -I here too.
            cSettings: isLinuxBuild ? [.unsafeFlags(rclLinuxIncludeFlags)] : [],
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    targets.append(
        .executableTarget(
            name: "crcl-loopback",
            dependencies: ["SwiftROS2", "SwiftROS2TestFixtures"],
            path: "Sources/Examples/CrclLoopback",
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    targets.append(
        .executableTarget(
            name: "crcl-nonbundled-loopback",
            dependencies: ["SwiftROS2", "SwiftROS2TestFixtures"],
            path: "Sources/Examples/CrclNonbundledLoopback",
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    targets.append(
        .executableTarget(
            name: "crcl-nonbundled-sub-loopback",
            dependencies: ["SwiftROS2", "SwiftROS2TestFixtures"],
            path: "Sources/Examples/CrclNonbundledSubLoopback",
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    targets.append(
        .executableTarget(
            name: "crcl-svc-loopback",
            dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
            path: "Sources/Examples/CrclSvcLoopback",
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    targets.append(
        .executableTarget(
            name: "crcl-action-loopback",
            dependencies: ["SwiftROS2", "SwiftROS2ExampleInterfaces"],
            path: "Sources/Examples/CrclActionLoopback",
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    targets.append(
        .executableTarget(
            name: "rcl-bench",
            dependencies: ["SwiftROS2", "SwiftROS2RCL", "SwiftROS2Bench", "SwiftROS2TestFixtures"],
            path: "Sources/Examples/RclBench",
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
    // rcl-soak samples RSS via Mach (`mach_task_basic_info` / `task_info` /
    // `mach_task_self_`) so its source is Apple-only; keep it out of the Linux
    // RCL graph (rcl-bench above is portable and stays). A Linux soak harness
    // would need a procfs/getrusage rewrite — out of scope for provisioning.
    if !isLinuxBuild {
        targets.append(
            .executableTarget(
                name: "rcl-soak",
                dependencies: ["SwiftROS2", "SwiftROS2RCL", "SwiftROS2Bench", "SwiftROS2TestFixtures"],
                path: "Sources/Examples/RclSoak",
                linkerSettings: [.linkedLibrary("c++")]
            ))
    }
    // The rmw-variant define must reach SwiftROS2RCL itself, not just the
    // umbrella: RclClient's zenoh-only behavior (the route-(b) fail-loud gate
    // and the AMENT_PREFIX_PATH synthesis) lives in this target and would be
    // dead code behind an undefined `#if SWIFT_ROS2_RCL_RMW_ZENOH` otherwise.
    var rclSwiftSettings: [SwiftSetting] = rclLinuxSwiftSettings
    if rclRmwVariant == "zenoh" {
        rclSwiftSettings.append(.define("SWIFT_ROS2_RCL_RMW_ZENOH"))
    }
    targets.append(
        .target(
            name: "SwiftROS2RCL",
            dependencies: [
                "CRclBridge", "CDDSBridge", "SwiftROS2Transport", "SwiftROS2Wire",
            ],
            path: "Sources/SwiftROS2RCL",
            swiftSettings: rclSwiftSettings
        ))
    products.append(.library(name: "SwiftROS2RCL", targets: ["SwiftROS2RCL"]))
    var rclTestsSwiftSettings: [SwiftSetting] = [.define("SWIFT_ROS2_RCL")]
    if rclRmwVariant == "zenoh" {
        rclTestsSwiftSettings.append(.define("SWIFT_ROS2_RCL_RMW_ZENOH"))
    }
    targets.append(
        .testTarget(
            name: "SwiftROS2RCLTests",
            dependencies: [
                "SwiftROS2", "SwiftROS2RCL", rosidl("SwiftROS2CDR"), rosidl("SwiftROS2Messages"), "CDDSBridge",
                "CRclBridge", "SwiftROS2TestFixtures",
            ],
            path: "Tests/SwiftROS2RCLTests",
            swiftSettings: rclTestsSwiftSettings,
            linkerSettings: isLinuxBuild ? rclLinuxLinkAll : [.linkedLibrary("c++")]
        ))
}

// Only pull in swift-docc-plugin when actually building documentation
// (env var `SWIFT_ROS2_DOCS_BUILD=1`). On Swift < 6.1, having the plugin
// active during `swift package diagnose-api-breaking-changes` clobbers
// the symbol-graph emission that the diagnose tool relies on, so every
// type reads as "removed" even when nothing changed. Gating the dep
// keeps `swift build`, `swift test`, and `diagnose-api-breaking-changes`
// unaffected; the docs-build CI job and the local docs script set the
// env var explicitly.
let isDocsBuild = ProcessInfo.processInfo.environment["SWIFT_ROS2_DOCS_BUILD"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/swift-ros2/swift-ros2-rosidl.git", from: "1.0.0-rc.2"),
]
if isDocsBuild {
    packageDependencies.append(.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"))
}

let package = Package(
    name: "swift-ros2",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
        .visionOS(.v1),
    ],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
