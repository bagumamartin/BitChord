#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/bitchord-lyrics-state-tests.XXXXXX")"
binary="$test_dir/tests"
trap 'rm -rf "$test_dir"' EXIT

swiftc -parse-as-library \
  -module-cache-path "$test_dir/module-cache" \
  "$repo/AppleApp/Sources/PlaybackSession/LyricsAlignmentState.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/LyricsLocaleCandidates.swift" \
  "$repo/AppleApp/tests/LyricsAlignmentStateTests.swift" \
  -o "$binary"
"$binary"

echo "lyrics alignment state checks passed"
