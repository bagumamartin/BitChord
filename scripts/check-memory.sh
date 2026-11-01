#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Expose the real interpreter constructor to this harness without changing its
# bindings or adding test-only entry points to the app.
python3 - "$repo" "$work" <<'PY'
from pathlib import Path
import sys
repo, work = map(Path, sys.argv[1:])
source = (repo / 'AppleApp/Sources/PlaybackSession/ModuleJsEngine.swift').read_text()
assert 'private final class Engine {' in source
(work / 'ModuleJsEngine.swift').write_text(source.replace('private final class Engine {', 'final class Engine {', 1))
cache = (repo / 'AppleApp/Sources/PlaybackSession/StreamFileCache.swift').read_text()
(work / 'DiskCache.swift').write_text('import Foundation\nimport CryptoKit\n' + cache[cache.index('enum DiskCache {'):])
PY
native="$repo/AppleApp/Frameworks/NativeCoreFFI.xcframework/macos-arm64"
shared="$repo/AppleApp/Frameworks/BitChordShared.xcframework/macos-arm64"
xcrun swiftc -O -disable-sandbox -parse-as-library -module-cache-path "$work/modules" -o "$work/verify" \
 -F "$native" -framework NativeCoreFFI -F "$shared" -framework BitChordShared \
 -framework CoreAudio -framework AudioToolbox -framework JavaScriptCore \
 -Xlinker -rpath -Xlinker "$shared/BitChordShared.framework/Versions/A" \
 "$repo/AppleApp/Generated/NativeCore.swift" "$work/ModuleJsEngine.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/LocalArtwork.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/OfflineArtworkStore.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/ArtworkRequests.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/QueueEntry.swift" \
 "$repo/AppleApp/Sources/App/GuardedHTTP.swift" "$work/DiskCache.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/LocalLibrary.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/LocalTrackOrder.swift" \
 "$repo/AppleApp/Sources/PlaybackSession/AutomixModelLoader.swift" \
 "$repo/scripts/memory-verify/main.swift"
MEMORY_FIXTURE="$repo/native-core/tests/fixtures/seek-tone.m4a" "$work/verify"
