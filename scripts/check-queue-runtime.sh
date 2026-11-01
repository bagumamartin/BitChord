#!/bin/bash
# Run controller checks on the host Mac, with silent local audio and mocked next replies.
set -euo pipefail
app="${1:?Pass the path to a Debug macOS BitChord.app}"
validation_dir="$(mktemp -d)"
trap 'cp "$validation_dir/runtime.log" /tmp/bitchord-queue-runtime-last.log 2>/dev/null || true; rm -rf "$validation_dir"' EXIT
validation_app="$validation_dir/BitChordQueueValidation.app"
ditto "$app" "$validation_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.bitchord.BitChord.queuevalidation.run-$RANDOM-$RANDOM" "$validation_app/Contents/Info.plist"
codesign --force --deep --sign - "$validation_app" > "$validation_dir/sign.log" 2>&1
rm -f /tmp/bitchord-queue-runtime.json
"$validation_app/Contents/MacOS/BitChord" --verify-queue > "$validation_dir/runtime.log" 2>&1
python3 - <<'PY'
import json
with open('/tmp/bitchord-queue-runtime.json') as f:
    report = json.load(f)
failed = [name for name, passed in report['checks'].items() if not passed]
assert report['passed'], f'Queue runtime checks failed: {failed}'
print(f"PASS {len(report['checks'])} Mac controller/runtime checks")
PY
