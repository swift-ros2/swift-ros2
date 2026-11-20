#!/usr/bin/env bash
# Build a universal Apple xcframework for either zenoh-pico or cyclonedds.
#
# Usage: Scripts/build-xcframework.sh <package> <output-dir>
#   <package>:   'zenoh-pico' | 'cyclonedds'
#   <output-dir>: directory to place the final artifact trio
#
# Produces (framework = CZenohPico or CCycloneDDS):
#   <output-dir>/<framework>.xcframework
#   <output-dir>/<framework>.xcframework.zip
#   <output-dir>/<framework>.xcframework.zip.checksum
#
# Slices:
#   iphoneos                 (arm64)
#   iphonesimulator          (arm64,x86_64)
#   macosx                   (arm64,x86_64)
#   maccatalyst              (arm64,x86_64)
#   xros                     (arm64)
#   xrsimulator              (arm64)
#
# Requires: cmake, xcodebuild, swift package (for compute-checksum), zip.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <zenoh-pico|cyclonedds> <output-dir>" >&2
    exit 1
fi

PKG="$1"
OUT="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.build/xc/$PKG"

mkdir -p "$OUT" "$WORK"
# Resolve absolute path AFTER mkdir so callers can pass paths whose
# parent directory doesn't yet exist (e.g. build/artifacts).
OUT="$(cd "$OUT" && pwd)"

case "$PKG" in
    zenoh-pico)  FRAMEWORK="CZenohPico"; LIB="libzenohpico.a" ;;
    cyclonedds)  FRAMEWORK="CCycloneDDS"; LIB="libddsc.a" ;;
    *)           echo "Unknown package: $PKG" >&2; exit 1 ;;
esac

build_slice() {
    local sdk="$1" archs="$2" deployment_target="$3" suffix="$4"
    local build_dir="$WORK/$suffix"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    local sdk_name="$sdk"
    local extra_c_flags=""
    local extra_cxx_flags=""
    # Always advertise Darwin to CMake. zenoh-pico's CMakeLists.txt
    # refuses CMAKE_SYSTEM_NAME=iOS/visionOS (see Conduit's build_deps.sh
    # for the same workaround).
    local cmake_system_name="Darwin"
    case "$sdk" in
        iphoneos|iphonesimulator|xros|xrsimulator)
            ;;
        macosx)
            ;;
        maccatalyst)
            sdk_name="macosx"
            local first_arch="${archs%%,*}"
            extra_c_flags="-target ${first_arch}-apple-ios${deployment_target}-macabi"
            extra_cxx_flags="$extra_c_flags"
            ;;
    esac

    local sdk_path
    sdk_path=$(xcrun --sdk "$sdk_name" --show-sdk-path)

    local cmake_osx_archs="${archs//,/;}"

    case "$PKG" in
        zenoh-pico)
            # FRAG_MAX_SIZE caps a received message that arrives in fragments;
            # a larger one is dropped. zenoh-pico's CMake default is 4096.
            #
            # Z_RUNTIME_MAX_TASKS sizes the session's executor. The session
            # itself uses four tasks and every publisher with a heartbeat one,
            # so the default of 64 would allow 60 such publishers per session.
            #
            # Z_TRANSPORT_CONNECT_TIMEOUT is how long an open waits for the
            # router's answer to the handshake. The default of 10 s equals
            # swift-ros2's default connection timeout, so an endpoint that
            # accepts TCP and stays silent would run into that one first.
            #
            # BUILD_TESTING=OFF: with the tests on, zenoh-pico compiles its
            # test hooks (Z_TEST_HOOKS) into the library.
            #
            # These options are the feature set of every swift-ros2 build. The
            # SwiftPM source builds (Linux, Windows, Android) take it from the
            # config.h committed in the fork
            # (vendor/zenoh-pico/include/zenoh-pico/config.h); zenoh-pico 1.10
            # generates this build's config.h into the build tree instead. The
            # two must be equal, which is checked after the slices are built:
            # when an option changes here, regenerate the committed file with
            # the same options.
            (cd "$build_dir" && cmake "$ROOT/vendor/zenoh-pico" \
                -DCMAKE_SYSTEM_NAME="$cmake_system_name" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_ARCHITECTURES="$cmake_osx_archs" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_INSTALL_PREFIX="$build_dir/install" \
                -DCMAKE_BUILD_TYPE=Release \
                -DBUILD_SHARED_LIBS=OFF \
                -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                -DCMAKE_C_FLAGS="$extra_c_flags" \
                -DCMAKE_CXX_FLAGS="$extra_cxx_flags" \
                -DZENOH_DEBUG=0 \
                -DBUILD_TESTING=OFF \
                -DBUILD_EXAMPLES=OFF \
                -DFRAG_MAX_SIZE=67108864 \
                -DZ_RUNTIME_MAX_TASKS=128 \
                -DZ_TRANSPORT_CONNECT_TIMEOUT=3000 \
                -DZ_FEATURE_LINK_TCP=1 \
                -DZ_FEATURE_LIVELINESS=1 \
                -DZ_FEATURE_INTEREST=1 \
                -DZ_FEATURE_MATCHING=1 \
                -DZ_FEATURE_UNSTABLE_API=1 \
                -DZ_FEATURE_ADVANCED_PUBLICATION=1 \
                -DZ_FEATURE_AUTO_RECONNECT=0)
            (cd "$build_dir" && cmake --build . --config Release -- -j"$(sysctl -n hw.ncpu)")
            (cd "$build_dir" && cmake --install .)
            ;;
        cyclonedds)
            (cd "$build_dir" && cmake "$ROOT/vendor/cyclonedds" \
                -DCMAKE_SYSTEM_NAME="$cmake_system_name" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target" \
                -DCMAKE_OSX_ARCHITECTURES="$cmake_osx_archs" \
                -DCMAKE_OSX_SYSROOT="$sdk_path" \
                -DCMAKE_INSTALL_PREFIX="$build_dir/install" \
                -DCMAKE_BUILD_TYPE=Release \
                -DBUILD_SHARED_LIBS=OFF \
                -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
                -DBUILD_EXAMPLES=OFF \
                -DBUILD_TESTING=OFF \
                -DBUILD_DDSPERF=OFF \
                -DBUILD_IDLC=OFF \
                -DENABLE_SSL=OFF \
                -DENABLE_SECURITY=OFF \
                -DENABLE_SHM=OFF \
                -DENABLE_LTO=OFF \
                -DENABLE_QOS_PROVIDER=OFF \
                -DENABLE_LIFESPAN=ON \
                -DENABLE_DEADLINE_MISSED=ON \
                -DENABLE_TYPE_DISCOVERY=OFF \
                -DENABLE_TOPIC_DISCOVERY=OFF \
                -DCMAKE_C_FLAGS="$extra_c_flags -fno-lto" \
                -DCMAKE_CXX_FLAGS="$extra_cxx_flags -fno-lto" \
                -DCMAKE_ASM_FLAGS="$extra_c_flags")
            (cd "$build_dir" && cmake --build . --config Release -- -j"$(sysctl -n hw.ncpu)")
            (cd "$build_dir" && cmake --install .)
            ;;
    esac

    # Move artifact to predictable location
    local lib_path
    lib_path=$(find "$build_dir/install" -name "$LIB" | head -1)
    if [[ -z "$lib_path" ]]; then
        echo "error: $LIB not found after building $suffix" >&2
        exit 1
    fi
    cp "$lib_path" "$build_dir/$LIB"
    echo "built $suffix: $build_dir/$LIB"
}

SLICES=(
    "iphoneos         arm64         16.0  iphoneos"
    "iphonesimulator  arm64,x86_64  16.0  iphonesimulator"
    "macosx           arm64,x86_64  13.0  macosx"
    "maccatalyst      arm64,x86_64  16.0  maccatalyst"
    "xros             arm64         1.0   xros"
    "xrsimulator      arm64         1.0   xrsimulator"
)

echo "building slices..."
for entry in "${SLICES[@]}"; do
    read -r sdk archs deploy suffix <<<"$entry"
    build_slice "$sdk" "$archs" "$deploy" "$suffix"
done

# Headers: for zenoh-pico we use the submodule include/ directly; for
# CycloneDDS we use the headers installed by the macosx slice (CMake's
# install step lays them out under <slice>/install/include).
case "$PKG" in
    zenoh-pico)
        HEADERS_DIR="$ROOT/vendor/zenoh-pico/include"
        # The xcframework ships the committed config.h with libraries that
        # were compiled with the generated one: refuse to package a mismatch
        # (a struct layout that depends on a feature flag would differ between
        # the library and its callers).
        committed_config="$HEADERS_DIR/zenoh-pico/config.h"
        for entry in "${SLICES[@]}"; do
            read -r _ _ _ suffix <<<"$entry"
            generated_config="$WORK/$suffix/include/zenoh-pico/config.h"
            if ! diff -u "$committed_config" "$generated_config"; then
                echo "error: $suffix was built with a config.h that differs from the committed" >&2
                echo "       $committed_config" >&2
                echo "       Regenerate that file in the zenoh-pico fork with this script's CMake options." >&2
                exit 1
            fi
        done
        ;;
    cyclonedds)
        HEADERS_DIR="$WORK/macosx/install/include"
        ;;
esac

echo "combining into xcframework..."
rm -rf "$OUT/${FRAMEWORK}.xcframework" "$OUT/${FRAMEWORK}.xcframework.zip"

XCARGS=(-create-xcframework)
for entry in "${SLICES[@]}"; do
    read -r _ _ _ suffix <<<"$entry"
    XCARGS+=(-library "$WORK/$suffix/$LIB" -headers "$HEADERS_DIR")
done
XCARGS+=(-output "$OUT/${FRAMEWORK}.xcframework")

xcodebuild "${XCARGS[@]}"

echo "zipping..."
(cd "$OUT" && zip -r -q "${FRAMEWORK}.xcframework.zip" "${FRAMEWORK}.xcframework")

echo "computing checksum..."
swift package --package-path "$ROOT" compute-checksum "$OUT/${FRAMEWORK}.xcframework.zip" \
    > "$OUT/${FRAMEWORK}.xcframework.zip.checksum"

echo ""
echo "done:"
echo "  $OUT/${FRAMEWORK}.xcframework"
echo "  $OUT/${FRAMEWORK}.xcframework.zip ($(du -h "$OUT/${FRAMEWORK}.xcframework.zip" | awk '{print $1}'))"
echo "  $OUT/${FRAMEWORK}.xcframework.zip.checksum ($(cat "$OUT/${FRAMEWORK}.xcframework.zip.checksum"))"
