#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -module-cache-path "$WORK/modules" -parse-as-library -o "$WORK/verify" \
  "$ROOT/AppleApp/Sources/PlaybackSession/OfflineCacheRules.swift" \
  "$ROOT/AppleApp/Sources/PlaybackSession/OfflinePlaybackSourcePolicy.swift" \
  "$ROOT/AppleApp/Sources/PlaybackSession/PlaybackLoadIntentPolicy.swift" \
  "$ROOT/AppleApp/Sources/PlaybackSession/StreamBitrateCapPolicy.swift" \
  "$ROOT/scripts/offline-cache-verify/main.swift"
"$WORK/verify"
