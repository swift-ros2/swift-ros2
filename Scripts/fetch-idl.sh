#!/usr/bin/env bash
# Downloads the upstream IDL pinned in idl.lock into .idl/<name>-<distribution>/.
# Each idl.lock line is "<name> <url> <distribution> <commit>"; '#' starts a comment.
# Every commit is fetched by its SHA (shallow) and verified, so the cache holds exactly the
# pinned trees. A directory already at its pinned commit is kept, so reruns are cheap.
# Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."
LOCK=${IDL_LOCK:-idl.lock}
CACHE=${IDL_CACHE:-.idl}
mkdir -p "$CACHE"
while read -r name url distro commit || [ -n "${name:-}" ]; do
  case "$name" in '' | '#'*) continue ;; esac
  if ! printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "fetch-idl: $name $distro: '$commit' is not a full commit SHA" >&2
    exit 1
  fi
  dir="$CACHE/$name-$distro"
  if [ -f "$dir/.commit" ] && [ "$(cat "$dir/.commit")" = "$commit" ]; then
    continue
  fi
  rm -rf "$dir" "$dir.tmp"
  git init -q "$dir.tmp"
  git -C "$dir.tmp" fetch -q --depth 1 "$url" "$commit"
  got=$(git -C "$dir.tmp" rev-parse FETCH_HEAD)
  if [ "$got" != "$commit" ]; then
    echo "fetch-idl: $name $distro: fetched $got, expected $commit" >&2
    exit 1
  fi
  git -C "$dir.tmp" checkout -q FETCH_HEAD
  rm -rf "$dir.tmp/.git"
  printf '%s\n' "$commit" > "$dir.tmp/.commit"
  mv "$dir.tmp" "$dir"
  echo "fetch-idl: $name $distro $commit"
done < "$LOCK"
