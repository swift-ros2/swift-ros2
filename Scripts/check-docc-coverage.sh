#!/usr/bin/env bash
# check-docc-coverage.sh
# Fail when a public or open Swift declaration in Sources/ lacks a /// comment
# on the line above it (attribute lines such as `@discardableResult` in
# between are skipped). Every declaration counts, at any indentation, with any
# modifiers (`public static func`, `public init`, `public subscript`,
# `nonisolated public func`, ...), not only top-level ones. Exempts
# re-export-only files and generated code (any `Generated/` directory; it is
# rewritten by the generators, so its comments belong in the generator).
#
# Declarations that were already undocumented when the check widened are
# listed in Scripts/docc-coverage-baseline.txt (one `<file>: <declaration>`
# line each, no line numbers, so unrelated edits do not churn it). Only
# declarations missing from the baseline fail the check; document a listed one
# and drop its line, or run with --update-baseline to rewrite the file from
# the current tree.
#
# Usage: Scripts/check-docc-coverage.sh [--update-baseline]

set -euo pipefail

cd "$(dirname "$0")/.."

BASELINE="Scripts/docc-coverage-baseline.txt"

declare -a EXEMPT_FILES=(
  "Sources/SwiftROS2/Exports.swift"
)

is_exempt() {
  [[ "$1" == */Generated/* ]] && return 0
  for f in "${EXEMPT_FILES[@]}"; do
    [[ "$1" == "$f" ]] && return 0
  done
  return 1
}

# Prints `<file>: <declaration>` for each undocumented public declaration,
# with the declaration's leading whitespace removed.
undocumented() {
  local file
  while IFS= read -r file; do
    if is_exempt "$file"; then continue; fi
    awk -v file="$file" '
      # Attribute-only lines sit between a doc comment and its declaration.
      /^[[:space:]]*@[A-Za-z_]+(\(.*\))?[[:space:]]*$/ { next }
      {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        # Inline attributes and modifiers that may come before the access level.
        decl = line
        while (decl ~ /^@[A-Za-z_]+(\([^)]*\))?[[:space:]]+/) {
          sub(/^@[A-Za-z_]+(\([^)]*\))?[[:space:]]+/, "", decl)
        }
        while (decl ~ /^(nonisolated|final|static|class|override|convenience|required|indirect|mutating|nonmutating|dynamic|lazy|weak|unowned)[[:space:]]+/) {
          sub(/^[a-z]+[[:space:]]+/, "", decl)
        }
        if (decl ~ /^(public|open)[[:space:]]/ && decl !~ /^public[[:space:]]+import[[:space:]]/) {
          if (prev !~ /^[[:space:]]*\/\/\//) {
            print file ": " line
          }
        }
        prev = $0
      }
    ' "$file"
  done < <(find Sources -name "*.swift" -type f | LC_ALL=C sort)
}

current="$(undocumented | LC_ALL=C sort)"

if [[ "${1:-}" == "--update-baseline" ]]; then
  {
    echo "# Public declarations without a /// comment, accepted by"
    echo "# Scripts/check-docc-coverage.sh. Document one and drop its line;"
    echo "# never add lines by hand. Regenerate with --update-baseline."
    if [[ -n "$current" ]]; then printf '%s\n' "$current"; fi
  } > "$BASELINE"
  echo "Wrote $(printf '%s' "$current" | grep -c '' || true) entries to $BASELINE."
  exit 0
fi

baseline=""
if [[ -f "$BASELINE" ]]; then
  baseline="$(grep -v '^#' "$BASELINE" | LC_ALL=C sort || true)"
fi

# Compared as multisets: two identical undocumented `public init(` lines in one
# file need two baseline lines.
new="$(LC_ALL=C comm -23 <(printf '%s\n' "$current" | sed '/^$/d') <(printf '%s\n' "$baseline" | sed '/^$/d'))"
fixed="$(LC_ALL=C comm -13 <(printf '%s\n' "$current" | sed '/^$/d') <(printf '%s\n' "$baseline" | sed '/^$/d'))"

if [[ -n "$fixed" ]]; then
  echo "note: these baseline entries are documented or gone now; drop them from $BASELINE:" >&2
  printf '  %s\n' "$fixed" | sed 's/^  $//' >&2
fi

if [[ -n "$new" ]]; then
  echo "" >&2
  echo "FAIL: public declarations without /// comments (not in $BASELINE):" >&2
  printf '%s\n' "$new" >&2
  exit 1
fi

echo "OK: every public declaration in Sources/ outside $BASELINE has a /// comment."
