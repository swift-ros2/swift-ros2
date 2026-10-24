#!/usr/bin/env bash
# Regenerates the internal (non-product) message targets used by examples and tests from the
# upstream IDL pinned in idl.lock. Only the types the examples and tests reference are emitted
# (--types); add a name to the matching list below when a new example or test needs another type
# (its field types are required too, e.g. TransformStamped needs Transform).
# distro_test_msgs is a test-only package whose IDL is committed under Tests/FixtureIDL/, one copy
# per distribution: its Plan gains a field in Lyrical, so its types differ among distributions.
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/fetch-idl.sh
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# swift-ros2-gen is rosidl's executable product: `swift run` builds and runs it at the version
# in Package.resolved (`swift build --product` only takes this package's own products).
gen() { swift run -c release swift-ros2-gen "$@"; }
DEPS=(--dependency "builtin_interfaces=.idl/rcl_interfaces-jazzy/builtin_interfaces@jazzy"
      --dependency "unique_identifier_msgs=.idl/unique_identifier_msgs-jazzy@jazzy")

EXAMPLE_TYPES=String,AddTwoInts,Trigger,Fibonacci
FIXTURE_TYPES=String,Header,Quaternion,Vector3,Imu,Temperature,Image,CompressedImage,PointCloud2,PointField,\
Transform,TransformStamped,TFMessage,TF2Error,LookupTransform,AudioData

gen --input "example_interfaces=.idl/example_interfaces-jazzy@jazzy" "${DEPS[@]}" \
  --module example_interfaces=SwiftROS2ExampleInterfaces --types "$EXAMPLE_TYPES" --output "$OUT/example"

F=SwiftROS2TestFixtures
gen \
  --input "std_msgs=.idl/common_interfaces-jazzy/std_msgs@jazzy" \
  --input "geometry_msgs=.idl/common_interfaces-jazzy/geometry_msgs@jazzy" \
  --input "sensor_msgs=.idl/common_interfaces-jazzy/sensor_msgs@jazzy" \
  --input "tf2_msgs=.idl/geometry2-jazzy/tf2_msgs@jazzy" \
  --input "audio_common_msgs=.idl/audio_common-jazzy/audio_common_msgs@jazzy" \
  "${DEPS[@]}" \
  --module std_msgs=$F --module geometry_msgs=$F --module sensor_msgs=$F \
  --module tf2_msgs=$F --module audio_common_msgs=$F --types "$FIXTURE_TYPES" --output "$OUT/fixtures"

gen \
  --input "distro_test_msgs=Tests/FixtureIDL/distro_test_msgs-jazzy@jazzy" \
  --input "distro_test_msgs=Tests/FixtureIDL/distro_test_msgs-lyrical@lyrical" \
  "${DEPS[@]}" --module distro_test_msgs=$F --output "$OUT/fixtures"

for pair in "example:SwiftROS2ExampleInterfaces" "fixtures:SwiftROS2TestFixtures"; do
  src=${pair%%:*}; dst=${pair##*:}
  rm -rf "Sources/$dst/Generated" && mkdir -p "Sources/$dst/Generated"
  find "$OUT/$src" -name '*.swift' -exec cp {} "Sources/$dst/Generated/" \;
done
