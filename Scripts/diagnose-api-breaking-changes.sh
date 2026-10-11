#!/usr/bin/env bash
# Wraps `swift package diagnose-api-breaking-changes` with a manual
# allowlist filter. SwiftPM 6.0.x's built-in `--breakage-allowlist-path`
# option does not reliably suppress matched breakages on macOS; this
# script reads the allowlist itself (one literal diagnostic message per
# line, comments / blank lines ignored) and exits 0 when every detected
# breakage is allowlisted.
#
# Usage:
#   diagnose-api-breaking-changes.sh <baseline-treeish> [allowlist-file]
#
# Without an allowlist, behaves exactly like the underlying SwiftPM
# command.

set -uo pipefail

BASELINE="${1:?baseline treeish required}"
ALLOWLIST="${2:-}"

OUTPUT_FILE=$(mktemp)
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
# Digest only the surviving library products. 2.0.0 removed the
# SwiftROS2Zenoh / SwiftROS2DDS products (the wire clients became `package`);
# without an explicit product list the digester aborts looking for their
# baseline ABI files instead of reporting breakages.
swift package diagnose-api-breaking-changes "$BASELINE" \
    --products SwiftROS2 --products SwiftROS2CDR --products SwiftROS2Messages \
    --products SwiftROS2Wire --products SwiftROS2Transport --products SwiftROS2Gen \
    2>&1 | tee "$OUTPUT_FILE"
EXIT=${PIPESTATUS[0]}
set -e

if [[ $EXIT -eq 0 ]]; then
    exit 0
fi

if [[ -z "$ALLOWLIST" || ! -f "$ALLOWLIST" ]]; then
    exit "$EXIT"
fi

# Every reported breakage line. The CLI prefix is `  💔 `; strip leading
# whitespace and the emoji so what remains starts with `API breakage:`,
# matching the exact format of the allowlist file. A breakage on a declaration
# that still exists (for example a protocol requirement that was added) is also
# printed as a compiler diagnostic, `<path>:<line>:<col>: warning: API breakage:
# ... [#api-digester-breaking-change]`; reduce it to the same bare message so a
# single allowlist line covers both forms.
DETECTED=$(grep -F 'API breakage:' "$OUTPUT_FILE" \
    | sed -E \
        -e 's/^[[:space:]]*💔[[:space:]]+//' \
        -e 's/^.*: warning: (API breakage:.*)$/\1/' \
        -e 's/ \[#api-digester-breaking-change\]$//')

# Allowed lines (drop comments and blank lines).
ALLOWED=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" || true)

UNEXPECTED=$(echo "$DETECTED" | grep -vFx -f <(echo "$ALLOWED") || true)

if [[ -z "$UNEXPECTED" ]]; then
    echo
    echo "All ${EXIT} detected breakages are allowlisted via $ALLOWLIST; passing." >&2
    exit 0
fi

echo
echo "Unexpected breakages (not allowlisted):" >&2
echo "$UNEXPECTED" >&2
exit "$EXIT"
