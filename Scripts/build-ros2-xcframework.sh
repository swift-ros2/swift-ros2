#!/usr/bin/env bash
# Build the real ROS 2 C/C++ stack for Apple slices and assemble an
# xcframework. Two rmw variants (select with RMW_VARIANT):
#   cyclonedds (default) — rcl + rmw_cyclonedds_cpp + rosidl introspection
#                          typesupport -> build/ros2/CRos2.xcframework
#   zenoh                — rcl + rmw_zenoh_cpp (no-SHM patch set under
#                          Scripts/ros2/patches/rmw_zenoh) + rosidl fastrtps
#                          typesupport (rmw_zenoh hard-codes it) + prebuilt
#                          zenoh-c staticlib (Rust; needs rustup/cargo on
#                          PATH) -> build/ros2zenoh/CRos2Zenoh.xcframework
# Usage: [RMW_VARIANT=zenoh] Scripts/build-ros2-xcframework.sh maccatalyst iphoneos
set -euo pipefail

# Use BASH_SOURCE (not $0) so ROOT resolves correctly whether the script is
# executed directly or `source`d (e.g. the verification commands that run
# individual functions via `bash -c 'source ...; cross_build ...'`).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RMW_VARIANT="${RMW_VARIANT:-cyclonedds}"
case "$RMW_VARIANT" in
  cyclonedds)
    BUILD="$ROOT/build/ros2"
    XCFW_NAME="CRos2"
    RMW_PKG=rmw_cyclonedds_cpp
    TS_C=rosidl_typesupport_introspection_c
    TS_CPP=rosidl_typesupport_introspection_cpp
    META="$ROOT/Scripts/ros2/colcon-defaults.meta"
    ;;
  zenoh)
    BUILD="$ROOT/build/ros2zenoh"
    XCFW_NAME="CRos2Zenoh"
    RMW_PKG=rmw_zenoh_cpp
    # rmw_zenoh_cpp resolves message types through the fastrtps typesupport
    # only (type_support_common.hpp hard-codes the identifier), so the single
    # static typesupport pin flips from introspection to fastrtps. The Swift
    # bridge is unaffected — it resolves handles via the rosidl_typesupport_c
    # dispatcher macros, which statically bind to whichever backend is pinned.
    TS_C=rosidl_typesupport_fastrtps_c
    TS_CPP=rosidl_typesupport_fastrtps_cpp
    META="$ROOT/Scripts/ros2/colcon-defaults-zenoh.meta"
    ;;
  *) echo "RMW_VARIANT must be 'cyclonedds' or 'zenoh'; got '$RMW_VARIANT'" >&2; exit 1 ;;
esac

# ROS 2 distribution of the RCL stack (spec D5: Lyrical replaces Jazzy). Every
# upstream pin the build consumes comes from this table; a staged-opt-in exit
# would add a `jazzy` row. Pick a new ros2/ros2 tag with:
#   git ls-remote --tags https://github.com/ros2/ros2.git 'refs/tags/release-<distro>-*' \
#     | grep -v beta | awk -F/ '{print $3}' | sort -V | tail -1
ROS2_DISTRO="${ROS2_DISTRO:-lyrical}"
resolve_distro_pins() {
  case "$ROS2_DISTRO" in
    lyrical)
      ROS2_RELEASE_TAG=release-lyrical-20260807                   # rcl 10.4.4, CycloneDDS 11.0.1
      RMW_ZENOH_BRANCH=lyrical
      RMW_ZENOH_PIN=2dfb794617d033021c6dddeab0238d1f01689db5      # rmw_zenoh_cpp 0.10.7
      ZENOHC_PIN=07b0d432121933cb368528153df000463292635d         # zenoh-c 1.10.1 + fixes (zenoh_cpp_vendor)
      ZENOHCPP_PIN=1e343e61b92a73af3bc247c178214bcc1042c34c
      AUDIO_COMMON_BRANCH=ros2
      AUDIO_COMMON_PIN=db2770b0ad703c474039914937974c764dc94351
      PCT_PLUGINS_BRANCH=lyrical
      PCT_PLUGINS_PIN=5e55a9491f86ba064a97570a1d961258cde6799f    # point_cloud_transport_plugins 6.2.0
      LIBYAML_PIN=2c891fc7a770e8ba2fec34fc6b545c672beb37e6        # libyaml 0.2.5
      TINYXML2_PIN=321ea883b7190d4e85cae5512a12e5eaa8f8731f       # tinyxml2 10.0.0
      ;;
    *) echo "ROS2_DISTRO must be 'lyrical'; got '$ROS2_DISTRO'" >&2; return 1 ;;
  esac
}
resolve_distro_pins
SRC="$BUILD/src_ws"
# The host generators and the python venv are rmw-agnostic; both variants
# share the cyclonedds tree's copies so the zenoh variant never rebuilds them.
HOST="$ROOT/build/ros2/host_ws"
VENV="$ROOT/build/ros2/venv"
TOOLCHAIN="$ROOT/Scripts/ros2/ios-cmake/ios.toolchain.cmake"
DEPLOY_IOS=16.0
# leetal ios-cmake enforces a Mac Catalyst minimum deployment target of 13.1
# (an iOS-style macabi version, not a macOS one).
DEPLOY_CATALYST=13.1
# clang raises a lower arm64 Mac Catalyst target to iOS 14.0 (macOS 11.0, the
# first arm64 macOS): -target arm64-apple-ios13.1-macabi yields minos 14.0, so
# 14.0 is the oldest minos a Catalyst object can carry.
CATALYST_ARM64_MINOS=14.0
# Matches Package.swift's .macOS(.v13). Not the Catalyst 13.1 above: on macOS
# that number means macOS 13.1, and a consumer linking the slice at 13.0 would
# get "object file ... was built for newer 'macOS' version (13.1)" per object.
DEPLOY_MACOS=13.0
# visionOS versions are 1.x — passing the iOS target (16.0) to the xros /
# xrsimulator slices would be rejected by the visionOS SDK.
DEPLOY_VISIONOS=1.0
# std_srvs + example_interfaces carry the service types the M7 service shim
# registers (SetBool/Trigger/Empty, AddTwoInts); rcl_interfaces (parameter
# services) is already in the closure via rcl. rcl_action carries the action
# server/client API the M8 action shim drives; its typesupport deps
# (action_msgs, unique_identifier_msgs) are already in the closure, and
# example_interfaces brings the Fibonacci action wrapper types.
# tf2_msgs + audio_common_msgs + point_cloud_interfaces carry the three
# Conduit-critical message types (latched /tf_static TFMessage, microphone
# AudioData, Draco-compressed CompressedPointCloud2). tf2_msgs (ros2/geometry2)
# is part of the release's ros2.repos import; the other two repos are not, so
# import_extra_msg_sources clones + pins them explicitly.
PKGS_UP_TO=(rcl "$RMW_PKG" rcl_action builtin_interfaces std_msgs geometry_msgs sensor_msgs std_srvs example_interfaces tf2_msgs audio_common_msgs point_cloud_interfaces)
# C++ test-only / lint vendor packages get dragged into the --packages-up-to
# closure via <test_depend>, but never link into the runtime libraries. They
# build shared libs / executables (e.g. osrf_testing_tools_cpp's malloc
# interposition .dylib) that do not cross-compile to the static iOS/Catalyst
# toolchain. They are leaf test deps, so colcon's --packages-skip drops them
# without breaking the dependents' build closure.
SKIP_TEST_PKGS=(
  osrf_testing_tools_cpp performance_test_fixture
  gtest_vendor gmock_vendor google_benchmark_vendor
  mimick_vendor uncrustify_vendor
)

# Drop COLCON_IGNORE so colcon never discovers these subtrees and treats them
# as external (so dependents don't flag an unmet dependency — unlike
# --packages-skip). These cannot or need not be cross-compiled for a
# CycloneDDS-only, introspection-typesupport ROS 2 build:
#  - iceoryx: cyclonedds's shared-memory transport (POSIX-SHM RouDi daemon);
#    does not cross-compile to iOS, unusable in the app sandbox. CycloneDDS
#    configures fine without it (ENABLE_SHM=OFF).
#  - rmw_fastrtps / rmw_connextdds: rcl pulls every RMW via rmw_implementation's
#    runtime selection, but we use rmw_cyclonedds_cpp only
#    (RMW_IMPLEMENTATION_DISABLE_RUNTIME_SELECTION=ON). The Fast-DDS RMW drags
#    in the Fast-DDS middleware + foonathan_memory_vendor, whose nested
#    ExternalProject build does not cross-compile to iOS.
#  - Fast-DDS (fastrtps) + foonathan_memory_vendor: only reachable via
#    rmw_fastrtps; not needed. (Fast-CDR / rosidl_typesupport_fastrtps stay —
#    the fastrtps *typesupport* only needs fastcdr, which cross-compiles.)
IGNORE_SUBTREES=(
  eclipse-iceoryx/iceoryx
  ros2/rmw_fastrtps
  ros2/rmw_connextdds
  ros2/rosidl_dynamic_typesupport_fastrtps
  eProsima/Fast-DDS
  eProsima/foonathan_memory_vendor
  # noop logging (RCL_LOGGING_IMPLEMENTATION=rcl_logging_noop) makes the
  # default spdlog logging backend unnecessary; drop it and its vendor.
  ros2/rcl_logging/rcl_logging_spdlog
  ros2/spdlog_vendor
  # rosidl_generator_py emits Python C-extension bindings for every message
  # package. Generation is driven by which generators are discoverable in the
  # ament prefix (not by buildtool_depend), so its mere presence in the host
  # tools forces a libpython-linked .dylib per message type — which fails to
  # cross-compile to iOS (links the host's macOS Python framework). We consume
  # ROS 2 from C/C++/Swift only, so drop the Python generator entirely; message
  # packages then generate just the C/C++/introspection typesupports.
  ros2/rosidl_python
  # Lyrical: rosidl_buffer_py is the pybind11 Python C-extension for the new
  # rosidl_buffer type, pulled in by rosidl_core_runtime's export deps. It is
  # Python-only (same reason as rosidl_python) and Lyrical's ros2.repos no
  # longer vendors pybind11, so drop it.
  ros2/rosidl/rosidl_buffer_py
  # Lyrical: rcl_logging_implementation is a dlopen-based runtime selector
  # (default rcl_logging_spdlog). rcl links rcl_logging_noop statically
  # (RCL_LOGGING_IMPLEMENTATION in the colcon meta) and only find_packages the
  # selector in dynamic mode, but rcl's package.xml still pulls it into the
  # closure. Built, it lands in librclros.a next to rcl_logging_noop with the
  # same rcl_logging_external_* symbols, and the linker resolves them to the
  # selector (archive order) — which would dlopen spdlog at runtime. Drop it.
  ros2/rcl_logging/rcl_logging_implementation
  # Lyrical: rmw_test_fixture_implementation is the test-isolation shim behind
  # run_rmw_isolated; it also builds a host-libpython-linked Python extension.
  # Nothing here runs it. It is skipped by COLCON_IGNORE rather than
  # --packages-skip because ament_cmake_ros exec-depends on it, and a skipped
  # package that is not in the host tools leaves its dependents without an
  # environment script ("Failed to find ... package.sh").
  ros2/ament_cmake_ros/rmw_test_fixture_implementation
)
ignore_unbuildable() {
  local rel
  for rel in "${IGNORE_SUBTREES[@]}"; do
    if [[ -d "$SRC/$rel" ]]; then touch "$SRC/$rel/COLCON_IGNORE"; fi
  done
  if [[ "$RMW_VARIANT" == zenoh ]]; then
    # The zenoh variant carries no CycloneDDS at all — drop the rmw and the
    # middleware so the slice build never compiles them.
    for rel in ros2/rmw_cyclonedds eclipse-cyclonedds/cyclonedds; do
      if [[ -d "$SRC/$rel" ]]; then touch "$SRC/$rel/COLCON_IGNORE"; fi
    done
  fi
  if [[ "$RMW_VARIANT" == cyclonedds ]]; then
    # Lyrical's ros2.repos carries ros2/rmw_zenoh (Jazzy's did not), and
    # rmw_implementation build-depends on rmw_zenoh_cpp, which drags
    # zenoh_cpp_vendor (cargo) and rosidl_buffer_backend_registry (pluginlib)
    # into the closure. The cyclonedds variant carries no Zenoh — drop it.
    for rel in ros2/rmw_zenoh; do
      if [[ -d "$SRC/$rel" ]]; then touch "$SRC/$rel/COLCON_IGNORE"; fi
    done
  fi
}

# A source patch whose anchor moved upstream would otherwise be skipped
# silently. After patch_sources each file must be absent, carry our marker,
# or no longer contain the code the patch exists for (upstream fixed it).
require_patched() {  # $1 file, $2 marker regex, $3 regex of the code the patch fixes (optional)
  [[ -f "$1" ]] || return 0
  grep -Eq "$2" "$1" && return 0
  if [[ -n "${3:-}" ]] && ! grep -Eq "$3" "$1"; then return 0; fi
  echo "patch_sources: $1 still needs its patch (marker $2 missing) — did the anchor move?" >&2
  return 1
}

# CycloneDDS's POSIX ifaddrs backend includes <net/if_media.h> on Apple to
# guess the interface media type. That header ships in the macOS / Mac
# Catalyst SDK but NOT in the iOS device / simulator SDK. Insert an
# __has_include-guarded Apple branch that stubs guess_iftype where the header
# is absent (iOS); Catalyst/macOS keep the real media query. Idempotent.
patch_sources() {
  # Each patch below carries its own existence + already-applied guard so a
  # previously-patched file never short-circuits the later patches.
  # Route (B): the wire .dds transport links this CycloneDDS too, so it carries
  # the iOS Wi-Fi UDP padding of the wire fork (swift-ros2/cyclonedds 7290b22e).
  # The reverse check makes it idempotent; an anchor that moved makes
  # `git apply` fail, which stops the build (set -e).
  local cdds_src="$SRC/eclipse-cyclonedds/cyclonedds"
  local pad_patch="$ROOT/Scripts/ros2/patches/cyclonedds/0001-ddsi_udp-pad-short-rtps-datagrams-for-ios-wifi.patch"
  # Fail closed: a missing CycloneDDS source must not silently ship CRos2
  # without the padding (the zenoh variant carries no CycloneDDS to patch).
  [[ "$RMW_VARIANT" != cyclonedds || -d "$cdds_src" ]] \
    || { echo "patch_sources: CycloneDDS source missing at $cdds_src" >&2; return 1; }
  if [[ "$RMW_VARIANT" == cyclonedds ]] \
      && ! git -C "$cdds_src" apply --reverse --check "$pad_patch" 2>/dev/null; then
    git -C "$cdds_src" apply "$pad_patch"
  fi

  local f="$SRC/eclipse-cyclonedds/cyclonedds/src/ddsrt/src/ifaddrs/posix/ifaddrs.c"
  # Lyrical's cyclonedds (11.x) already guards that branch with !TARGET_OS_IPHONE, so the stub below would redefine guess_iftype and hide <net/if_dl.h> (LLADDR) on iOS; skip it there.
  if [[ -f "$f" ]] && ! grep -q "SWIFT_ROS2_IOS_IFTYPE_STUB" "$f" && ! grep -q "TARGET_OS_IPHONE" "$f"; then
    local tmp; tmp="$(mktemp)"
    awk '
      /^#elif defined\(__APPLE__\) \|\| defined\(__QNXNTO__\)/ && !done {
        print "#elif defined(__APPLE__) && !__has_include(<net/if_media.h>) /* SWIFT_ROS2_IOS_IFTYPE_STUB */"
        print "static enum ddsrt_iftype guess_iftype (const struct ifaddrs *sys_ifa) { (void) sys_ifa; return DDSRT_IFTYPE_UNKNOWN; }"
        done = 1
      }
      { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
  fi

  # Lyrical's cyclonedds (11.x) adds a BSD/Apple raw-Ethernet transport that
  # includes <net/bpf.h>; the iOS device/simulator SDK does not ship it. Gate
  # the Apple arm of ddsi_raweth.c on the header so iOS falls through to the
  # file's own `#else` stub (ddsi_raweth_init returns 0, raweth unavailable);
  # macOS/Catalyst keep the real BPF path. Absent from 0.10.x trees (the line
  # below does not exist there), so the guard short-circuits. Idempotent.
  local rawf="$SRC/eclipse-cyclonedds/cyclonedds/src/core/ddsi/src/ddsi_raweth.c"
  local raw_orig='#if (defined(__linux) || defined(__FreeBSD__) || defined(__QNXNTO__) || defined(__APPLE__)) && !LWIP_SOCKET'
  if [[ -f "$rawf" ]] && ! grep -q "SWIFT_ROS2_IOS_NO_BPF" "$rawf" && grep -qxF "$raw_orig" "$rawf"; then
    local tmp3; tmp3="$(mktemp)"
    awk -v orig="$raw_orig" '
      $0 == orig && !done {
        print "#if (defined(__linux) || defined(__FreeBSD__) || defined(__QNXNTO__) || (defined(__APPLE__) && __has_include(<net/bpf.h>))) && !LWIP_SOCKET /* SWIFT_ROS2_IOS_NO_BPF */"
        done = 1
        next
      }
      { print }
    ' "$rawf" > "$tmp3" && mv "$tmp3" "$rawf"
  fi

  # rcl exports rcl_logging_interface but not the concrete logging
  # implementation it links (RCL_LOGGING_IMPLEMENTATION=rcl_logging_noop,
  # pinned in both colcon-defaults.meta and colcon-defaults-zenoh.meta —
  # the dds and zenoh variants share this patch). With static libraries
  # the implementation target
  # stays in rcl's exported link interface, so the first downstream
  # find_package(rcl) consumer (rcl_action, added in M8) fails with
  # "rcl_logging_noop::rcl_logging_noop ... target was not found". Export the
  # selected implementation alongside the interface so rclConfig.cmake pulls
  # it in via find_dependency. Idempotent.
  local rcl_cmake="$SRC/ros2/rcl/rcl/CMakeLists.txt"
  if [[ -f "$rcl_cmake" ]] && ! grep -q 'ament_export_dependencies(${RCL_LOGGING_IMPLEMENTATION})' "$rcl_cmake"; then
    local tmp2; tmp2="$(mktemp)"
    awk '
      { print }
      /^ament_export_dependencies\(rcl_logging_interface\)$/ && !done {
        print "ament_export_dependencies(${RCL_LOGGING_IMPLEMENTATION})"
        done = 1
      }
    ' "$rcl_cmake" > "$tmp2" && mv "$tmp2" "$rcl_cmake"
  fi

  # Lyrical rcutils (7.1.x) initializes a C11 atomic with a braced scalar
  # initializer, which Apple clang 21 (Xcode 27) rejects as "illegal
  # initializer type 'atomic_int_least64_t'" in every -std mode. Upstream
  # rolling already switched non-MSVC builds to a plain scalar initializer;
  # apply the same one-line fix. Idempotent.
  local fi_c="$SRC/ros2/rcutils/src/testing/fault_injection.c"
  if [[ -f "$fi_c" ]] && grep -q '^static atomic_int_least64_t g_rcutils_fault_injection_count = {-1};$' "$fi_c"; then
    sed -i '' 's/^static atomic_int_least64_t g_rcutils_fault_injection_count = {-1};$/static atomic_int_least64_t g_rcutils_fault_injection_count = -1;  \/\* SWIFT_ROS2_ATOMIC_INIT \*\//' "$fi_c"
  fi

  # Lyrical rcl 10.4.4 (rcl_yaml_param_parser) makes strtod locale-independent
  # with C11 call_once from <threads.h>, which Apple SDKs do not ship ("fatal
  # error: 'threads.h' file not found"). The rcl `lyrical` branch (post-10.4.4)
  # and rolling already carry an Apple branch that maps call_once onto
  # pthread_once and pulls newlocale/uselocale from <xlocale.h>; apply the
  # same change. Idempotent.
  local yaml_c="$SRC/ros2/rcl/rcl_yaml_param_parser/src/parse.c"
  if [[ -f "$yaml_c" ]] && grep -q '^#include <threads.h>$' "$yaml_c" \
      && ! grep -q "SWIFT_ROS2_APPLE_CALL_ONCE" "$yaml_c"; then
    perl -0pi -e '
      s{#include <locale.h>\n}{#include <locale.h>\n#ifdef __APPLE__  /* SWIFT_ROS2_APPLE_CALL_ONCE */\n#include <xlocale.h>\n#endif\n};
      s{#include <windows.h>\n#else\n#include <threads.h>\n}{#include <windows.h>\n#elif defined(__APPLE__)\n#include <pthread.h>\ntypedef pthread_once_t once_flag;\n#define ONCE_FLAG_INIT PTHREAD_ONCE_INIT\n#define call_once(flag, func) pthread_once((flag), (func))\n#else\n#include <threads.h>\n};
    ' "$yaml_c"
  fi

  # Lyrical adds rosidl_buffer, a C++ runtime library that rosidl_runtime_c
  # (sequence __fini -> rosidl_buffer_uint8_destroy) and every generated
  # introspection typesupport with a uint8[] field
  # (rosidl_buffer_uint8_throw_if_not_cpu) now call into. Its CMakeLists
  # hard-codes add_library(... SHARED), so the slice build installs a .dylib
  # that merge_slice (static archives only) skips, leaving both symbols
  # undefined at app link time. Build it static when BUILD_SHARED_LIBS is
  # explicitly OFF (the slice builds); keep SHARED otherwise — the host tools
  # build links it into the shared, C-linked librosidl_runtime_c, where a
  # static C++ archive would leave the libc++ symbols unresolved. Idempotent.
  local rb_cmake="$SRC/ros2/rosidl/rosidl_buffer/CMakeLists.txt"
  if [[ -f "$rb_cmake" ]] && ! grep -q "SWIFT_ROS2_STATIC_ROSIDL_BUFFER" "$rb_cmake" \
      && grep -q '^add_library(${PROJECT_NAME} SHARED$' "$rb_cmake"; then
    perl -0pi -e '
      s{\nadd_library\(\$\{PROJECT_NAME\} SHARED\n}{\n# SWIFT_ROS2_STATIC_ROSIDL_BUFFER\nif(DEFINED BUILD_SHARED_LIBS AND NOT BUILD_SHARED_LIBS)\n  set(_swift_ros2_rosidl_buffer_type STATIC)\nelse()\n  set(_swift_ros2_rosidl_buffer_type SHARED)\nendif()\nadd_library(\$\{PROJECT_NAME\} \$\{_swift_ros2_rosidl_buffer_type\}\n};
    ' "$rb_cmake"
  fi

  # Zenoh variant (Lyrical): rmw_zenoh_cpp links rosidl_buffer_backend_registry
  # (pluginlib -> class_loader), and both hard-code SHARED, so the slice build
  # would install .dylibs that merge_slice skips. Build them static when
  # BUILD_SHARED_LIBS is explicitly OFF (same rule as rosidl_buffer above).
  # Neither is in the cyclonedds closure (rmw_zenoh is COLCON_IGNOREd there)
  # or in the host-tools closure, and the rule keeps SHARED when
  # BUILD_SHARED_LIBS is unset, so both stay unchanged. Idempotent.
  local rbr_cmake="$SRC/ros2/rosidl/rosidl_buffer_backend_registry/CMakeLists.txt"
  if [[ -f "$rbr_cmake" ]] && ! grep -q "SWIFT_ROS2_STATIC_BUFFER_BACKEND_REGISTRY" "$rbr_cmake" \
      && grep -q '^add_library(${PROJECT_NAME} SHARED$' "$rbr_cmake"; then
    perl -0pi -e '
      s{\nadd_library\(\$\{PROJECT_NAME\} SHARED\n}{\n# SWIFT_ROS2_STATIC_BUFFER_BACKEND_REGISTRY\nif(DEFINED BUILD_SHARED_LIBS AND NOT BUILD_SHARED_LIBS)\n  set(_swift_ros2_registry_type STATIC)\nelse()\n  set(_swift_ros2_registry_type SHARED)\nendif()\nadd_library(\$\{PROJECT_NAME\} \$\{_swift_ros2_registry_type\}\n};
    ' "$rbr_cmake"
  fi
  local cl_cmake="$SRC/ros/class_loader/CMakeLists.txt"
  if [[ -f "$cl_cmake" ]] && ! grep -q "SWIFT_ROS2_STATIC_CLASS_LOADER" "$cl_cmake" \
      && grep -q '^find_package(console_bridge_vendor REQUIRED)' "$cl_cmake"; then
    perl -0pi -e '
      s{\nfind_package\(console_bridge_vendor REQUIRED\)}{\n# SWIFT_ROS2_STATIC_CLASS_LOADER\nif(DEFINED BUILD_SHARED_LIBS AND NOT BUILD_SHARED_LIBS)\n  set(explicit_library_type "STATIC")\nendif()\n\nfind_package(console_bridge_vendor REQUIRED)};
    ' "$cl_cmake"
  fi

  # Every patch above is silent when its anchor is missing; fail the build
  # instead when a file ended up neither patched nor fixed upstream.
  require_patched "$f" 'SWIFT_ROS2_IOS_IFTYPE_STUB|TARGET_OS_IPHONE'
  require_patched "$rawf" 'SWIFT_ROS2_IOS_NO_BPF' 'net/bpf\.h'
  require_patched "$rcl_cmake" 'ament_export_dependencies\(\$\{RCL_LOGGING_IMPLEMENTATION\}\)'
  require_patched "$fi_c" 'SWIFT_ROS2_ATOMIC_INIT' '= \{-1\};$'
  require_patched "$yaml_c" 'SWIFT_ROS2_APPLE_CALL_ONCE' '^#include <threads\.h>$'
  require_patched "$rb_cmake" 'SWIFT_ROS2_STATIC_ROSIDL_BUFFER' '^add_library\(\$\{PROJECT_NAME\} SHARED$'
  if [[ "$RMW_VARIANT" == zenoh ]]; then
    require_patched "$rbr_cmake" 'SWIFT_ROS2_STATIC_BUFFER_BACKEND_REGISTRY' '^add_library\(\$\{PROJECT_NAME\} SHARED$'
    require_patched "$cl_cmake" 'SWIFT_ROS2_STATIC_CLASS_LOADER'
  fi
  if [[ "$RMW_VARIANT" == cyclonedds ]]; then
    git -C "$cdds_src" apply --reverse --check "$pad_patch" \
      || { echo "patch_sources: the CycloneDDS UDP padding is not applied" >&2; return 1; }
  fi
}

mkdir -p "$BUILD"

# CMake 4.x removed compatibility with cmake_minimum_required(VERSION < 3.5).
# Some bundled sources still declare old minimums (e.g. libyaml, pulled by
# libyaml_vendor's ExternalProject). CMake honours CMAKE_POLICY_VERSION_MINIMUM
# from the environment, which propagates to every nested cmake invocation
# (colcon -> cmake -> ExternalProject -> inner cmake), unlike a -D on the outer
# command line. Pin it so old projects still configure under CMake 4.x.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

setup_venv() {
  if [[ ! -d "$VENV" ]]; then
    python3.11 -m venv "$VENV"
    # shellcheck disable=SC1091
    source "$VENV/bin/activate"
    pip install -r "$ROOT/Scripts/ros2/requirements.txt"
  fi
  # Always activate: import_sources runs `vcs import`, and vcstool comes from
  # the venv (requirements.txt). With a pre-existing venv (the zenoh variant
  # reuses the cyclonedds tree's) the early return used to leave PATH on
  # whatever `vcs` the host has (here a Homebrew one with a dead interpreter).
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
}

import_sources() {
  # Re-import when the release tag changes: a Jazzy-era src_ws must never be
  # reused for Lyrical. The marker is written only after a complete import, so
  # an interrupted import starts over.
  local tag_marker="$SRC/.swift-ros2-ros2-release"
  if [[ ! -f "$tag_marker" || "$(cat "$tag_marker")" != "$ROS2_RELEASE_TAG" ]]; then
    rm -rf "$SRC" "$BUILD/ros2-meta"
    mkdir -p "$SRC"
    git clone --depth 1 --branch "$ROS2_RELEASE_TAG" https://github.com/ros2/ros2.git "$BUILD/ros2-meta"
    # The vcs import covers every repo in the release's ros2.repos set — including
    # ros2/geometry2, which carries tf2_msgs — so a fresh workspace needs no
    # extra step for the tf2_msgs package.
    ( cd "$SRC" && vcs import < "$BUILD/ros2-meta/ros2.repos" )
    echo "$ROS2_RELEASE_TAG" > "$tag_marker"
  fi
  import_zenoh_sources
  import_extra_msg_sources
  import_libyaml_source
}

# Lyrical's libyaml_vendor no longer builds libyaml — it only ships a
# Findyaml.cmake that looks for a system libyaml (CONFIG, then pkg-config).
# Cross builds then silently pick up the host's Homebrew libyaml headers via
# pkg-config and leave yaml_* undefined in librclros.a. Clone libyaml 0.2.5
# (the version Jazzy's libyaml_vendor built) into the source tree instead:
# colcon builds it as a plain CMake package named `yaml`, which rcl and
# rcl_yaml_param_parser <depend> on, so it joins the --packages-up-to closure,
# Findyaml's CONFIG lookup finds it ahead of pkg-config, and its
# install/lib/libyaml.a is merged like any other package archive.
import_libyaml_source() {
  local dest="$SRC/yaml/libyaml"
  if [[ -d "$dest" && "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$LIBYAML_PIN" ]]; then return 0; fi
  rm -rf "$dest"
  git clone --branch 0.2.5 https://github.com/yaml/libyaml.git "$dest"
  git -C "$dest" checkout "$LIBYAML_PIN"
}

# Conduit-critical message repos that are NOT in the release's ros2.repos set —
# clone + pin explicitly (same pattern as the rmw_zenoh pin in
# import_zenoh_sources). Only the msg-only package in each repo is built: every
# sibling package (the gstreamer-based audio pipelines in audio_common, the
# draco/zlib/zstd transport plugin packages in point_cloud_transport_plugins)
# pulls dependencies that do not cross-compile to the static Apple toolchain,
# so they get COLCON_IGNOREd.
import_msg_only_repo() {  # $1=url $2=branch $3=pin $4=dest $5=package-to-keep
  local url="$1" branch="$2" pin="$3" dest="$4" keep="$5"
  # Re-clone when the checkout is missing or not at the pin (same guard as
  # import_libyaml_source), so a stale tree never feeds the build.
  if [[ ! -d "$dest" || "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" != "$pin" ]]; then
    rm -rf "$dest"
    git clone --branch "$branch" --single-branch "$url" "$dest"
    git -C "$dest" checkout "$pin"
  fi
  # COLCON_IGNORE every sibling package dir. Runs on every invocation (not
  # just after a fresh clone) so pre-existing checkouts pick the markers up.
  local pkg
  for pkg in "$dest"/*/; do
    [[ -f "$pkg/package.xml" ]] || continue
    [[ "$(basename "$pkg")" == "$keep" ]] && continue
    touch "${pkg}COLCON_IGNORE"
  done
}

# AUDIO_COMMON_BRANCH is audio_common's `ros2` branch (the ROS 2 development
# branch, released into jazzy) — audio_common_msgs 3.x. PCT_PLUGINS_BRANCH is
# point_cloud_transport_plugins' `lyrical` branch — point_cloud_interfaces
# (CompressedPointCloud2, the type Conduit publishes for Draco LiDAR). Branches
# and pins come from resolve_distro_pins.
import_extra_msg_sources() {
  import_msg_only_repo https://github.com/ros-drivers/audio_common.git \
    "$AUDIO_COMMON_BRANCH" "$AUDIO_COMMON_PIN" "$SRC/ros-drivers/audio_common" audio_common_msgs
  import_msg_only_repo https://github.com/ros-perception/point_cloud_transport_plugins.git \
    "$PCT_PLUGINS_BRANCH" "$PCT_PLUGINS_PIN" "$SRC/ros-perception/point_cloud_transport_plugins" point_cloud_interfaces
}

# RMW_ZENOH_PIN is rmw_zenoh_cpp 0.10.7, the `lyrical` branch tip — the commit
# the no-SHM patch set under Scripts/ros2/patches/rmw_zenoh is rebased onto.
# Lyrical's ros2.repos itself pins rmw_zenoh 0.10.5.
import_zenoh_sources() {
  [[ "$RMW_VARIANT" == zenoh ]] || return 0
  local rz="$SRC/ros2/rmw_zenoh"
  # Lyrical's ros2.repos carries ros2/rmw_zenoh (0.10.5), so the vcs import
  # already created $rz. Replace that copy with the pinned clone exactly once
  # and apply the patch set to it. The marker records the pin plus a hash of
  # the patch set and is written only after every patch applied, so a re-run
  # neither re-applies the patches nor skips them, an interrupted run starts
  # over from a fresh clone, and a changed pin or patch set re-clones.
  local marker="$rz/.swift-ros2-pinned"
  local want
  want="$RMW_ZENOH_PIN $(cat "$ROOT/Scripts/ros2/patches/rmw_zenoh"/*.patch | shasum -a 256 | cut -d' ' -f1)"
  if [[ ! -f "$marker" || "$(cat "$marker")" != "$want" ]]; then
    rm -rf "$rz"
    git clone --branch "$RMW_ZENOH_BRANCH" --single-branch https://github.com/ros2/rmw_zenoh.git "$rz"
    git -C "$rz" checkout "$RMW_ZENOH_PIN"
    # zenoh's shared-memory subsystem hard-fails to compile for target_os=ios
    # and rmw_zenoh_cpp has no no-SHM build mode; the patch set guards every
    # SHM use behind Z_FEATURE_SHARED_MEMORY (absent in our zenoh-c build),
    # makes the library static, and skips the host-only targets (rmw_zenohd,
    # the rmw_zenoh_cpp_test_fixture plugin) when cross-compiling.
    local p
    for p in "$ROOT/Scripts/ros2/patches/rmw_zenoh"/*.patch; do
      git -C "$rz" apply "$p"
    done
    echo "$want" > "$marker"
  fi
  [[ "$(git -C "$rz" rev-parse HEAD)" == "$RMW_ZENOH_PIN" ]] || {
    echo "rmw_zenoh: HEAD is not RMW_ZENOH_PIN ($RMW_ZENOH_PIN)" >&2; return 1; }
  local p
  for p in "$ROOT/Scripts/ros2/patches/rmw_zenoh"/*.patch; do
    git -C "$rz" apply --reverse --check "$p" \
      || { echo "rmw_zenoh: $(basename "$p") is not applied" >&2; return 1; }
  done
  import_tinyxml2_source
  # zenoh_cpp_vendor (an ament_vendor cargo wrapper) is replaced by the
  # prebuilt per-slice zenoh-c prefix (build_zenohc). COLCON_IGNORE makes
  # colcon treat it as external, so rmw_zenoh_cpp's
  # find_package(zenoh_cpp_vendor) resolves through CMAKE_PREFIX_PATH to the
  # hand-assembled config instead of driving cargo inside the colcon graph.
  touch "$rz/zenoh_cpp_vendor/COLCON_IGNORE"
}

# Lyrical's rmw_zenoh_cpp depends on rosidl_buffer_backend_registry, which
# depends on pluginlib, which find_packages a system TinyXML2. Lyrical's
# ros2.repos dropped tinyxml2_vendor and the host has no tinyxml2, so clone
# tinyxml2 into the source tree (same pattern as libyaml): colcon builds it as
# the CMake package `tinyxml2` that pluginlib <depend>s on, so it joins the
# zenoh closure and pluginlib's find_package(TinyXML2) resolves to its config.
import_tinyxml2_source() {
  local dest="$SRC/leethomason/tinyxml2"
  if [[ -d "$dest" && "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$TINYXML2_PIN" ]]; then return 0; fi
  rm -rf "$dest"
  git clone --branch 10.0.0 https://github.com/leethomason/tinyxml2.git "$dest"
  git -C "$dest" checkout "$TINYXML2_PIN"
}

build_host_tools() {
  # colcon writes install/setup.sh before the packages build, so it cannot
  # tell a finished host build from a failed one. Our own stamp is written
  # only after colcon succeeds, keyed on the release tag.
  [[ "$(cat "$HOST/.swift-ros2-host-ok" 2>/dev/null)" == "$ROS2_RELEASE_TAG" ]] && return 0
  rm -rf "$HOST"
  ignore_unbuildable
  patch_sources
  # shellcheck disable=SC1091
  # The venv is shared from the cyclonedds tree (VENV, rmw-agnostic) — NOT
  # $BUILD/venv, which does not exist for the zenoh variant on a clean
  # checkout (the CI zenoh leg builds host tools before any cyclonedds run).
  source "$VENV/bin/activate"
  colcon --log-base "$HOST/log" build \
    --base-paths "$SRC" \
    --build-base "$HOST/build" --install-base "$HOST/install" \
    --merge-install \
    --packages-up-to rosidl_default_generators rosidl_typesupport_introspection_c \
    --cmake-args -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release
  echo "$ROS2_RELEASE_TAG" > "$HOST/.swift-ros2-host-ok"
}

slice_platform() { case "$1" in
  maccatalyst) echo "MAC_CATALYST_ARM64 $DEPLOY_CATALYST" ;;
  macosx)      echo "MAC_ARM64 $DEPLOY_MACOS" ;;
  iphoneos)    echo "OS64 $DEPLOY_IOS" ;;
  iphonesimulator) echo "SIMULATORARM64 $DEPLOY_IOS" ;;
  xros)        echo "VISIONOS $DEPLOY_VISIONOS" ;;
  xrsimulator) echo "SIMULATOR_VISIONOS $DEPLOY_VISIONOS" ;;
  *) echo "unknown slice: $1" >&2; return 1 ;; esac; }

zenohc_triple() { case "$1" in
  maccatalyst) echo aarch64-apple-ios-macabi ;;
  macosx)      echo aarch64-apple-darwin ;;
  iphoneos)    echo aarch64-apple-ios ;;
  iphonesimulator) echo aarch64-apple-ios-sim ;;
  # visionOS: prebuilt rust-std exists on stable (1.96+), but zenoh-c's
  # dependency graph does not compile for the target yet (pnet_sys 0.35
  # lacks visionOS cfg — timeval field-width mismatch). Until upstream pnet
  # catches up, the zenoh variant ships without visionOS slices; visionOS
  # consumers stay on the zenoh-pico wire path or the .dds transport.
  xros|xrsimulator) echo "zenoh variant: zenoh-c deps (pnet_sys) do not build for visionOS; slice dropped by design" >&2; return 1 ;;
  *) echo "zenoh variant: no stable Rust std for slice '$1'" >&2; return 1 ;; esac; }

# Cross-build zenoh-c (Rust staticlib) and assemble the CMake prefix that
# satisfies rmw_zenoh_cpp's find_package(zenoh_cpp_vendor / zenohc /
# zenohcxx). The feature set is rmw_zenoh's pin minus shared-memory: zenoh-shm
# gates platform support and compile_error!s for iOS targets, which is exactly
# what the patch set compensates for on the C++ side.
# ZENOHC_PIN / ZENOHCPP_PIN are rmw_zenoh lyrical's zenoh_cpp_vendor pins
# (zenoh-c 1.10.1 + fixes; zenoh-cpp is the header-only C++ API). The vendor
# pins commits, not tags.
build_zenohc() {  # $1 = slice -> $BUILD/$slice/zenohc-install
  local slice="$1"
  # Explicit failures: this runs under `||` / `if` in sourced use, where set -e
  # is suspended, and an unknown slice must never reach the rm -rf below.
  local triple; triple="$(zenohc_triple "$slice")" || return 1
  local zc="$BUILD/zenoh-c" zcpp="$BUILD/zenoh-cpp"
  local out="$BUILD/$slice/zenohc-install"
  # The stamp covers the slice's deployment target too: a build tree reused
  # across a target change would otherwise ship objects built for the old one.
  local pd deploy
  pd="$(slice_platform "$slice")" || return 1
  read -r _ deploy <<< "$pd"
  [[ -n "$triple" && -n "$deploy" ]] || return 1
  local stamp="$ZENOHC_PIN $ZENOHCPP_PIN $deploy"
  [[ -f "$out/lib/libzenohc.a" && "$(cat "$out/.pins" 2>/dev/null)" == "$stamp" ]] && return 0
  if [[ "$(git -C "$zc" rev-parse HEAD 2>/dev/null)" != "$ZENOHC_PIN" ]]; then
    rm -rf "$zc"; git clone https://github.com/eclipse-zenoh/zenoh-c.git "$zc"; git -C "$zc" checkout "$ZENOHC_PIN"
  fi
  if [[ "$(git -C "$zcpp" rev-parse HEAD 2>/dev/null)" != "$ZENOHCPP_PIN" ]]; then
    rm -rf "$zcpp"; git clone https://github.com/eclipse-zenoh/zenoh-cpp.git "$zcpp"; git -C "$zcpp" checkout "$ZENOHCPP_PIN"
  fi
  # zenoh-c pins its Rust toolchain via rust-toolchain.toml (currently
  # 1.97.1; rustup installs it on first use); running `rustup target add` inside the checkout installs the
  # std for THAT toolchain, not the default one (E0463 otherwise).
  ( cd "$zc" && rustup target add "$triple" )
  # Without these, cc-rs compiles ring's C objects for the SDK's own version
  # (minos 27.0 with Xcode 27) instead of our deployment targets.
  local ios_dt="$DEPLOY_IOS"
  [[ "$slice" == maccatalyst ]] && ios_dt="$DEPLOY_CATALYST"
  # cargo does not fingerprint the deployment-target variables, so a reused
  # target dir keeps rustc's and cc-rs's objects built for the previous target.
  # Drop this triple's output when the target changed; the marker is written
  # before the build so a retry after a failed build still resumes.
  local tdir="$zc/target/$triple"
  if [[ "$(cat "$tdir/.swift-ros2-deploy" 2>/dev/null)" != "$deploy" ]]; then
    rm -rf "$tdir"
    mkdir -p "$tdir"
    echo "$deploy" > "$tdir/.swift-ros2-deploy"
  fi
  # Scoped to the cargo invocation: exported, they would leak into the later
  # colcon steps and the next slice.
  ( cd "$zc" && IPHONEOS_DEPLOYMENT_TARGET="$ios_dt" MACOSX_DEPLOYMENT_TARGET="$DEPLOY_MACOS" \
      cargo build --release -j 4 --target "$triple" \
      --features unstable --features transport_serial )
  rm -rf "$out"
  mkdir -p "$out/lib/cmake" "$out/share/zenoh_cpp_vendor/cmake"
  # cargo's build.rs regenerates the header set (zenoh_configure.h carries the
  # feature macros — Z_FEATURE_SHARED_MEMORY must be absent) into the target
  # dir; zenoh-cpp contributes the header-only C++ API.
  cp -R "$zc/target/$triple/release/include" "$out/include"
  cp -R "$zcpp/include/zenoh" "$out/include/zenoh"
  cp "$zcpp/include/zenoh.hxx" "$out/include/"
  cp "$zc/target/$triple/release/libzenohc.a" "$out/lib/"
  cp -R "$ROOT/Scripts/ros2/zenohc-cmake/zenohc" "$out/lib/cmake/zenohc"
  cp -R "$ROOT/Scripts/ros2/zenohc-cmake/zenohcxx" "$out/lib/cmake/zenohcxx"
  cp "$ROOT/Scripts/ros2/zenohc-cmake/zenoh_cpp_vendor/zenoh_cpp_vendorConfig.cmake" \
     "$out/share/zenoh_cpp_vendor/cmake/"
  echo "$stamp" > "$out/.pins"
}

cross_build() {  # $1 = slice, $2... = extra --packages-up-to
  local slice="$1"; shift
  # Explicit failure, not set -e: under `||` / `if` an unknown slice would leave
  # $sb pointing outside the slice tree and the rm -rf below would follow it.
  local pd platform deploy
  pd="$(slice_platform "$slice")" || return 1
  read -r platform deploy <<< "$pd"
  [[ -n "$platform" && -n "$deploy" ]] || return 1
  local sb="$BUILD/$slice"
  # ios.toolchain.cmake prepends its flags (including -target) to the cached
  # CMAKE_*_FLAGS on every configure and clang takes the last -target, so a tree
  # configured for another deployment target keeps compiling for the old one. A
  # tree without this marker predates it. Start the slice over when its target
  # changed; the marker is written before colcon so a retry after a failed
  # build resumes.
  if [[ -d "$sb/build" && "$(cat "$sb/.swift-ros2-deploy" 2>/dev/null)" != "$platform $deploy" ]]; then
    rm -rf "$sb/build" "$sb/install"
  fi
  mkdir -p "$sb"
  echo "$platform $deploy" > "$sb/.swift-ros2-deploy"
  ignore_unbuildable
  patch_sources
  local extra_cmake=()
  if [[ "$RMW_VARIANT" == zenoh ]]; then
    build_zenohc "$slice"
    extra_cmake+=(-DCMAKE_PREFIX_PATH="$sb/zenohc-install")
  fi
  # ament_vendor forwards CMAKE_TOOLCHAIN_FILE to its nested ExternalProject
  # builds (e.g. libyaml) but NOT the toolchain's required PLATFORM var, so the
  # nested cmake bails with "PLATFORM argument not set". The leetal toolchain
  # also reads PLATFORM from ENV{_PLATFORM}, so export it as a real environment
  # variable — it propagates through colcon -> make -> ExternalProject -> cmake.
  export _PLATFORM="$platform"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  # colcon-generated setup.sh references unbound vars (COLCON_CURRENT_PREFIX);
  # relax `set -u` only while sourcing it, then restore strict mode.
  set +u
  # shellcheck disable=SC1091
  source "$HOST/install/setup.sh"
  set -u
  STATIC_ROSIDL_TYPESUPPORT_C="$TS_C" \
  STATIC_ROSIDL_TYPESUPPORT_CPP="$TS_CPP" \
  colcon --log-base "$sb/log" build \
    --base-paths "$SRC" \
    --build-base "$sb/build" --install-base "$sb/install" \
    --merge-install \
    --metas "$META" \
    --packages-up-to "$@" \
    --packages-skip "${SKIP_TEST_PKGS[@]}" \
    --cmake-args \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
      -DPLATFORM="$platform" -DDEPLOYMENT_TARGET="$deploy" \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
      -DCMAKE_MAKE_PROGRAM=/usr/bin/make \
      -DFORCE_BUILD_VENDOR_PKG=ON \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release \
      ${extra_cmake[@]+"${extra_cmake[@]}"}
}

merge_slice() {  # $1 = slice -> build/ros2/<slice>/merged/{librclros.a,include}
  # Separate `local` statements: `local a=$1 b=$BUILD/$a` expands $a before it
  # is localized, which trips `set -u` ("a: unbound variable").
  local slice="$1"
  slice_platform "$slice" > /dev/null || return 1  # never rm -rf for an unknown slice
  local sb="$BUILD/$slice"
  local out="$sb/merged"
  rm -rf "$out"; mkdir -p "$out"
  # Merge all static archives into one. install/lib/*.a are the ament packages;
  # install/opt/*/lib/*.a are vendor packages whose ament_vendor build installs
  # into a private opt prefix (e.g. libyaml from libyaml_vendor) — both are
  # needed or the static link leaves undefined symbols.
  #
  # Use `libtool -static` directly on the archives rather than `ar x` + re-pack.
  # CycloneDDS's libddsc.a contains duplicate member names (random.c.o,
  # time.c.o, ... — a generic and a platform variant); `ar x` overwrites them
  # on disk, silently dropping the object that defines symbols like
  # _ddsrt_random. libtool merges archives while preserving duplicate members.
  local archives=()
  local a
  shopt -s nullglob
  for a in "$sb/install/lib/"*.a "$sb/install/opt/"*/lib/*.a; do archives+=("$a"); done
  shopt -u nullglob
  # The zenoh variant links the prebuilt Rust staticlib into the merged
  # archive so consumers still link exactly one library.
  if [[ "$RMW_VARIANT" == zenoh ]]; then
    archives+=("$sb/zenohc-install/lib/libzenohc.a")
  fi
  libtool -static -o "$out/librclros.a" "${archives[@]}"
  cp -R "$sb/install/include" "$out/include"
  # ROS 2 installs headers doubled: include/<pkg>/<pkg>/foo.h, consumed as
  # <pkg/foo.h>. An xcframework exposes a single headers dir as one search
  # path, so collapse the doubled level (include/<pkg>/<pkg>/* ->
  # include/<pkg>/*) so <pkg/foo.h> resolves. Non-doubled trees (CycloneDDS
  # dds/ddsc, idl, fastcdr) are already at the right level and left as-is.
  local p name
  for p in "$out/include"/*/; do
    name="$(basename "$p")"
    if [[ -d "$p$name" ]]; then
      ( shopt -s dotglob nullglob; mv "$p$name"/* "$p" )
      rmdir "$p$name" 2>/dev/null || true
    fi
  done
  # Keep only C headers. The umbrella module is consumed from C (the rcl C
  # API: rcl/rmw/rcutils/rosidl_runtime_c are all .h). C++ headers (.hpp:
  # rosidl_runtime_cpp, rcpputils, message C++ builders, fastcdr) pull
  # <algorithm> etc. and break the module when built in C mode; they are not
  # needed for the C publish path, so drop them.
  find "$out/include" -type f ! -name '*.h' -delete
  # libyaml and tinyxml2 install top-level headers; in the flattened
  # build-products include dir they would shadow a consumer's own copies.
  rm -f "$out/include/yaml.h" "$out/include/tinyxml2.h"
  # Drop the fastrtps typesupport from the public umbrella: fastcdr ships C++
  # under a .h extension (Cdr.h includes <array>) and every message package's
  # per-type *__rosidl_typesupport_fastrtps_c.h pulls fastcdr/Cdr.h — both
  # break the C umbrella module. The publish path uses the introspection
  # typesupport only; the fastrtps typesupport objects stay in librclros.a as
  # harmless dead weight (nothing references them), just not in the headers.
  rm -rf "$out/include/fastcdr" \
         "$out/include/rosidl_typesupport_fastrtps_c" \
         "$out/include/rosidl_typesupport_fastrtps_cpp"
  find "$out/include" -name '*rosidl_typesupport_fastrtps*' -delete
  # CycloneDDS headers. Route (B): the cyclonedds variant keeps dds/, because
  # CDDSBridge (the wire .dds bridge) compiles against the CycloneDDS inside
  # librclros.a. The module map lists only CRos2.h, so dds/ stays textual and
  # compiles only where CDDSBridge includes it. ddsc/, idl/ and idlc/ are
  # tooling headers nothing consumes.
  if [[ "$RMW_VARIANT" != cyclonedds ]]; then rm -rf "$out/include/dds"; fi
  rm -rf "$out/include/ddsc" "$out/include/idl" "$out/include/idlc"
  find "$out/include" -type d -empty -delete
}

version_max() { printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }

# No object in a slice's librclros.a may be built for an OS newer than the slice
# itself: a consumer linking at the package's own minimum (Package.swift) gets
# "object file ... was built for newer '<OS>' version" for every such object
# (the macosx slice once shipped at 13.1 against .macOS(.v13)). Older is fine,
# because Rust's prebuilt std and other objects may carry a lower minos.
# `otool -l` prints every archive member in one pass. The target is in
# LC_BUILD_VERSION (Mach-O platform number + minos; Mac Catalyst minos is
# iOS-style) or, for objects that predate it, in LC_VERSION_MIN_<OS> (its
# `version`; the Rust std objects of the zenoh iOS slices are such members).
# LC_VERSION_MIN_IPHONEOS carries no simulator distinction, so it is accepted in
# both iOS slices. Members with neither command are counted but not checked.
assert_object_targets() {  # $1 = slice
  local slice="$1" a="$BUILD/$1/merged/librclros.a"
  local pnum pname limit deploy pd
  pd="$(slice_platform "$slice")" || return 1
  read -r _ deploy <<< "$pd"
  case "$slice" in
    macosx)          pnum=1;  pname=MACOS ;;
    iphoneos)        pnum=2;  pname=IOS ;;
    maccatalyst)     pnum=6;  pname=MACCATALYST ;;
    iphonesimulator) pnum=7;  pname=IOSSIMULATOR ;;
    xros)            pnum=11; pname=VISIONOS ;;
    xrsimulator)     pnum=12; pname=VISIONOSSIMULATOR ;;
    *) echo "assert: unknown slice: $slice" >&2; return 1 ;;
  esac
  limit="$deploy"
  [[ "$slice" == maccatalyst ]] && limit="$(version_max "$deploy" "$CATALYST_ARM64_MINOS")"
  local report n vmn members bad newest
  report="$(otool -l "$a" 2>/dev/null | awk -v ar="$a" -v want="$pnum" -v limit="$limit" '
    function ver(s,    p) { split(s, p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }
    function vmplat(c) {
      if (c == "LC_VERSION_MIN_MACOSX") return 1
      if (c == "LC_VERSION_MIN_IPHONEOS") return 2
      if (c == "LC_VERSION_MIN_TVOS") return 3
      if (c == "LC_VERSION_MIN_WATCHOS") return 4
      return 0
    }
    # p = platform number, v = minos / version, how = "" or the LC_VERSION_MIN_* command
    function check(p, v, how,    ok, x) {
      x = ver(v)
      if (x > newest_v) { newest_v = x; newest = v }
      ok = (p == want) || (how != "" && p == 2 && want == 7)
      if (!ok || x > lim) {
        bad++
        if (bad <= 20) printf "BAD %s: platform %s%s, minos %s\n", member, p, (how != "" ? " (" how ")" : ""), v
      }
    }
    BEGIN { lim = ver(limit) }
    /^[^ ].*\):$/ && $1 != "Load" {
      members++
      member = $0
      if (index(member, ar "(") == 1) member = substr(member, length(ar) + 2)
      sub(/\):$/, "", member)
      cmd = ""
      next
    }
    $1 == "cmd" { cmd = $2; next }
    cmd == "LC_BUILD_VERSION" && $1 == "platform" { plat = $2; next }
    cmd == "LC_BUILD_VERSION" && $1 == "minos" { n++; check(plat, $2, ""); cmd = ""; next }
    cmd ~ /^LC_VERSION_MIN_/ && $1 == "version" { vmn++; check(vmplat(cmd), $2, cmd); cmd = ""; next }
    END { printf "SUMMARY %d %d %d %d %s\n", n, vmn, members, bad, newest }
  ')" || true
  read -r _ n vmn members bad newest <<< "$(printf '%s\n' "$report" | grep '^SUMMARY ' || true)"
  if [[ -z "${n:-}" || "$((n + vmn))" == 0 ]]; then
    echo "assert: no LC_BUILD_VERSION / LC_VERSION_MIN_* objects found in $a (did the otool -l format change?)" >&2
    return 1
  fi
  if [[ "$bad" != 0 ]]; then
    echo "assert: $bad of $((n + vmn)) objects in librclros.a are not built for $pname <= $limit (the $slice slice):" >&2
    printf '%s\n' "$report" | grep '^BAD ' | sed 's/^BAD /  /' >&2
    [[ "$bad" -le 20 ]] || echo "  ... and $((bad - 20)) more" >&2
    return 1
  fi
  echo "assert: $slice: $members members: $n LC_BUILD_VERSION, $vmn LC_VERSION_MIN_* (checked), $((members - n - vmn)) without either (unchecked); newest minos $newest (limit $limit, platform $pname)"
}

# Facts every slice must satisfy (spike change list, "post-merge assertions").
assert_merged_slice() {  # $1 = slice
  local sb="$BUILD/$1" a="$BUILD/$1/merged/librclros.a" fail=0
  # libcycloneddsidl*.dylib are the idlc compiler's own libraries (idlc links
  # them), built because the cyclonedds closure builds idlc; nothing in
  # librclros.a references them, so they are tooling, not runtime.
  local dylibs; dylibs="$(find "$sb/install/lib" -name '*.dylib' ! -name 'libcycloneddsidl*' 2>/dev/null)"
  [[ -z "$dylibs" ]] || { echo "assert: unmerged runtime dylibs: $dylibs" >&2; fail=1; }
  local undef
  undef="$(comm -23 <(nm -u "$a" 2>/dev/null | awk 'NF{print $NF}' | sort -u) \
                    <(nm -gU "$a" 2>/dev/null | awk 'NF==3{print $3}' | sort -u) \
           | grep -E '^_(rosidl_buffer_|yaml_)' || true)"
  [[ -z "$undef" ]] || { echo "assert: undefined in librclros.a: $undef" >&2; fail=1; }
  local logging; logging="$(nm -gU -A "$a" 2>/dev/null | grep ' T _rcl_logging_external_initialize$' || true)"
  [[ "$(printf '%s\n' "$logging" | grep -c .)" == 1 && "$logging" == *noop* ]] \
    || { echo "assert: _rcl_logging_external_initialize is not the single noop one: $logging" >&2; fail=1; }
  local dds; dds="$(nm -gU "$a" 2>/dev/null | grep -c ' T _dds_create_participant$' || true)"
  local want=1; [[ "$RMW_VARIANT" == zenoh ]] && want=0
  [[ "$dds" == "$want" ]] || { echo "assert: $dds CycloneDDS builds in librclros.a (want $want)" >&2; fail=1; }
  # Route (B): CDDSBridge compiles against the headers of this CycloneDDS (the
  # version check and the pinned release both read dds/version.h), so merge_slice
  # must ship dds/dds.h and dds/version.h in the cyclonedds variant.
  if [[ "$RMW_VARIANT" == cyclonedds ]]; then
    local h
    for h in dds/dds.h dds/version.h; do
      [[ -f "$sb/merged/include/$h" ]] \
        || { echo "assert: merged include dir is missing $h (route (B) needs it)" >&2; fail=1; }
    done
  fi
  # Host Homebrew headers or libraries in a slice's cache entries (the libyaml
  # leak the spike hit). cmake / python living under /opt/homebrew is fine,
  # so only *_INCLUDE_DIR(S) / *_LIBRARY / *_LIBRARIES entries count, and the
  # host interpreter's own FindPython3 entries (_Python3_INCLUDE_DIR,
  # _Python3_LIBRARY_RELEASE, ...) are not a leak: no Python is linked in.
  local leaks
  leaks="$(grep -HE '^[A-Za-z0-9_]*(INCLUDE_DIRS?|LIBRARY|LIBRARIES)[A-Za-z0-9_]*:[A-Z]+=.*/opt/homebrew' \
           "$sb"/build/*/CMakeCache.txt 2>/dev/null \
           | grep -vE 'CMakeCache\.txt:_?(Python[0-9]*|PYTHON[0-9]*)_' || true)"
  [[ -z "$leaks" ]] || { echo "assert: Homebrew paths in slice CMake caches: $leaks" >&2; fail=1; }
  assert_object_targets "$1" || fail=1
  return $fail
}

assemble_xcframework() {  # $@ = slices
  local out="$BUILD/$XCFW_NAME.xcframework"
  rm -rf "$out"
  local args=()
  local slice m
  for slice in "$@"; do
    m="$BUILD/$slice/merged"
    cp "$ROOT/Scripts/ros2/module.modulemap" "$m/include/module.modulemap"
    cp "$ROOT/Scripts/ros2/CRos2.h" "$m/include/CRos2.h"
    args+=(-library "$m/librclros.a" -headers "$m/include")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$out"
}

# rmw_zenoh_cpp resolves its default session config through the ament index
# at runtime; apps and the local smoke point AMENT_PREFIX_PATH at this mini
# prefix (index marker + the json5 configs).
assemble_zenoh_ament_prefix() {
  [[ "$RMW_VARIANT" == zenoh ]] || return 0
  local ap="$BUILD/ament-prefix"
  mkdir -p "$ap/share/ament_index/resource_index/packages" \
           "$ap/share/rmw_zenoh_cpp/config"
  touch "$ap/share/ament_index/resource_index/packages/rmw_zenoh_cpp"
  # Lyrical: every rmw_zenoh context creates a BufferBackendRegistry, whose
  # pluginlib::ClassLoader("rosidl_buffer_backend", ...) first resolves that
  # package through the ament index. Without the marker it throws (caught;
  # logs an ERROR on every rmw init). With the marker and no
  # rosidl_buffer_backend__pluginlib__plugin resources, it finds zero plugin
  # classes, so no backend library is ever dlopened.
  touch "$ap/share/ament_index/resource_index/packages/rosidl_buffer_backend"
  cp "$SRC/ros2/rmw_zenoh/rmw_zenoh_cpp/config/"*.json5 \
     "$ap/share/rmw_zenoh_cpp/config/"
}

# Top-level dispatch when invoked directly (not sourced) with slice args.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  setup_venv
  import_sources
  build_host_tools
  for slice in "$@"; do
    cross_build "$slice" "${PKGS_UP_TO[@]}"
    merge_slice "$slice"
    assert_merged_slice "$slice"
  done
  assemble_xcframework "$@"
  assemble_zenoh_ament_prefix
fi
