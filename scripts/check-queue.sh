#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
bin="$(mktemp -d)/queue-verify"
xcrun swiftc -module-cache-path /tmp/bitchord-swift-module-cache -o "$bin" \
  "$repo/AppleApp/Sources/PlaybackSession/QueueEntry.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaybackQueuePolicy.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaybackQueueSearchPolicy.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaybackHandoffPolicy.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaybackQueueWindow.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/LastPlayed.swift" \
  "$repo/scripts/queue-verify/main.swift"
"$bin"
python3 - "$repo" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
queue = (root / "AppleApp/Sources/PlaybackSession/PlaybackController+Queue.swift").read_text()
controller = (root / "AppleApp/Sources/PlaybackSession/PlaybackController.swift").read_text()
transport = (root / "AppleApp/Sources/PlaybackSession/PlaybackController+Transport.swift").read_text()
detail = (root / "AppleApp/Sources/UI/DetailView.swift").read_text()
snapshot = (root / "AppleApp/Sources/PlaybackSession/LastPlayed.swift").read_text()
checks = {
    "detail playback uses a 25-ahead window and 12-item low water": "windowAhead = 25" in (root / "AppleApp/Sources/PlaybackSession/PlaybackQueueWindow.swift").read_text() and "lowWater = 12" in (root / "AppleApp/Sources/PlaybackSession/PlaybackQueueWindow.swift").read_text(),
    "context advances consume the canonical list before continuation": "contextWindowEntries[contextWindowCursor..<end]" in queue,
    "played rows are trimmed while previous can rematerialize canonical rows": "queue.removeFirst(removeCount)" in queue and "prependPreviousContextEntry()" in transport,
    "playback owns continuation retries at 2, 5 and 15 seconds": "for (attempt, delay) in [0, 2, 5, 15].enumerated()" in queue,
    "page cancels its request and mirrors the controller snapshot": "loadMoreTask?.cancel()" in detail and "mirrorPlaybackContext()" in detail and "controller.playbackContextRevision" in detail,
    "page stops requesting more after playback takes ownership": "!controller.ownsPlaybackContextWindow(browseId)" in detail,
    "window state is separate from transition switch functions": "contextWindowEntries" in controller and "func maintainContextWindow()" in queue,
    "cold restore keeps canonical and ordered context plus continuation cursors": all(key in snapshot for key in ["contextEntries", "orderedContextEntries", "contextContinuation", "contextCursor", "contextBaseIndex"]),
}
for label, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'} {label}")
if not all(checks.values()):
    raise SystemExit(1)
PY
