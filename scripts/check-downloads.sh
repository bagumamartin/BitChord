#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
fixture_pid=''
trap 'cp "$WORK/server.log" /tmp/bitchord-download-fixture-last.log 2>/dev/null || true; if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi; rm -rf "$WORK"' EXIT
python3 "$ROOT/scripts/downloads-verify/network_fixture.py" "$WORK/port" > "$WORK/server.log" 2>&1 &
fixture_pid=$!
for attempt in $(seq 1 100); do [ -f "$WORK/port" ] && break; sleep 0.05; done
test -f "$WORK/port"
export BITCHORD_DOWNLOAD_TEST_BASE_URL="http://127.0.0.1:$(cat "$WORK/port")"
# Compile the production queue model without pulling the entire UI into this harness.
python3 - "$ROOT" "$WORK" <<'PY'
import sys
from pathlib import Path
root, work = map(Path, sys.argv[1:])
(work/'QueueEntry.swift').write_text((root/'AppleApp/Sources/PlaybackSession/QueueEntry.swift').read_text())
PY
NATIVE="$ROOT/AppleApp/Frameworks/NativeCoreFFI.xcframework/macos-arm64"
SHARED="$ROOT/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
xcrun swiftc -module-cache-path "$WORK/modules" -parse-as-library -o "$WORK/verify" \
 -F "$NATIVE" -framework NativeCoreFFI -F "$SHARED" -framework BitChordShared \
 -framework CoreAudio -framework AudioToolbox \
 -Xlinker -rpath -Xlinker "$SHARED/BitChordShared.framework/Versions/A" \
 "$ROOT/AppleApp/Generated/NativeCore.swift" "$WORK/QueueEntry.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/DownloadStore.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/DownloadActivity.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/AudioDownloadContainer.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/StreamFileCache.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/CanvasMediaRequest.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/FileDownloadTransport.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/LocalArtwork.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/PlaybackDebugLog.swift" \
 "$ROOT/AppleApp/Sources/PlaybackSession/PlaybackRegionStore.swift" \
 "$ROOT/scripts/downloads-verify/NetworkChecks.swift" \
 "$ROOT/scripts/downloads-verify/main.swift"
"$WORK/verify"
