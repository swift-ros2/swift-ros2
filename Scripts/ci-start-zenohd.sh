#!/usr/bin/env bash
# Starts a standalone zenohd (the Zenoh version rmw_zenoh_cpp uses) in the background, listening on
# loopback only, and waits until it accepts connections. CI uses it to run the tests that are gated on
# ZENOH_ROUTER. Usage: Scripts/ci-start-zenohd.sh [port]  (default 7447)
set -euo pipefail

VERSION=1.10.1
PORT=${1:-7447}
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) TRIPLE=aarch64-apple-darwin ;;
  Darwin-x86_64) TRIPLE=x86_64-apple-darwin ;;
  Linux-x86_64) TRIPLE=x86_64-unknown-linux-gnu ;;
  Linux-aarch64) TRIPLE=aarch64-unknown-linux-gnu ;;
  *) echo "ci-start-zenohd: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

DIR=${RUNNER_TEMP:-/tmp}/zenoh-$VERSION
mkdir -p "$DIR"
curl -fsSL -o "$DIR/zenoh.zip" \
  "https://github.com/eclipse-zenoh/zenoh/releases/download/$VERSION/zenoh-$VERSION-$TRIPLE-standalone.zip"
unzip -q -o "$DIR/zenoh.zip" -d "$DIR"
chmod +x "$DIR/zenohd"
"$DIR/zenohd" --listen "tcp/127.0.0.1:$PORT" --no-multicast-scouting > "$DIR/zenohd.log" 2>&1 &

# Wait (bounded) for the listener instead of sleeping a fixed time.
for _ in $(seq 30); do
  if nc -z 127.0.0.1 "$PORT"; then
    echo "zenohd $VERSION listening on 127.0.0.1:$PORT"
    exit 0
  fi
  sleep 1
done
echo "::error::zenohd did not open 127.0.0.1:$PORT within 30 s"
cat "$DIR/zenohd.log"
exit 1
