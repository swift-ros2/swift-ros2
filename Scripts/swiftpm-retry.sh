#!/usr/bin/env bash
# swiftpm-retry.sh
# Run a SwiftPM command and retry it once when the SwiftPM process itself
# dies from a crash signal.
#
# On Linux, swift-corelibs-libdispatch has a use-after-free in its epoll
# muxnote bookkeeping (swiftlang/swift-corelibs-libdispatch#949): when a pipe
# read source is torn down while its EPOLLHUP is being delivered, the manager
# thread walks a freed muxnote and crashes in `_dispatch_event_loop_drain`.
# SwiftPM reads every subprocess's output through DispatchIO on pipes, so
# `swift build` and `swift test` occasionally segfault during build planning,
# before any test has run (swiftlang/swift-build#1786).
#
# Only a crash of the SwiftPM process is retried. A crashing test binary is a
# child of SwiftPM: `swift test` reports it ("exited with unexpected signal
# code 11") and exits 1, and this script passes that status through unchanged.
#
# Usage:
#   Scripts/swiftpm-retry.sh swift test --parallel

set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

for attempt in 1 2; do
    "$@"
    status=$?
    case "$status" in
        # SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGSEGV
        132 | 133 | 134 | 135 | 139) ;;
        *) exit "$status" ;;
    esac
    if [[ $attempt -eq 1 ]]; then
        echo "::warning::'$*' crashed with signal $((status - 128)); retrying once (swiftlang/swift-corelibs-libdispatch#949)" >&2
    fi
done
exit "$status"
