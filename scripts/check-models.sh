#!/bin/bash
# The Automix model downloads, against a fixture server.
#
# The app fetches every model at runtime — Beat This! final0, its Core ML
# compilation and open-unmix umxhq (all MIT); nothing is bundled. The parts of a
# download that can fail quietly are the parts a real download almost never shows
# you: a resumed transfer that starts over, a checksum that lets a truncated graph
# through, a metered connection that gets used after the listener said no. So this
# drives all of them through the real store — real URLSession, real SHA-256, real
# files, a real Apple Archive — against scripts/models-verify/fixture.py, which can
# be made to lie in the exact ways the code claims to defend against. Every model
# runs the same cases. It also pins the
# migration: the old 113 MB vocal download is removed on the first launch, the
# current vocals file is not, and a beat-only install leaves vocals notInstalled.
#
# Set MODELS_LIVE=1 to also download both real pinned graphs and check them against
# the size and digest in AutomixModelStore.swift, which is the only thing that
# catches the release assets drifting away from the manifest.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

work="$(mktemp -d)"
fixture_dir="$work/fixtures"
mkdir -p "$fixture_dir"

# The third download is an Apple Archive, so its fixture is one too: a tiny
# archive with the expected directory. The store's compiler is stubbed in the
# harness — the payload is not a model — but unpacking, verification and the
# `.mlmodelc` bookkeeping are the real code.
mkdir -p "$work/coreml-src/BeatThisFinal0.mlpackage"
printf '{"dummy": true}' > "$work/coreml-src/BeatThisFinal0.mlpackage/Manifest.json"
/usr/bin/aa archive -a raw -d "$work/coreml-src" -o "$fixture_dir/coreml.aar" || {
  echo "could not build the Core ML archive fixture" >&2
  exit 2
}

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

python3 "$here/models-verify/fixture.py" --dir "$fixture_dir" --port "$port" \
  > "$work/fixture.out" 2> "$work/fixture.err" &
fixture_pid=$!
cleanup() {
  kill "$fixture_pid" 2>/dev/null
  wait "$fixture_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

# Wait for the listener rather than sleeping a fixed amount: a slow machine would
# otherwise fail this check for being slow, which is not what it is measuring.
for _ in $(seq 1 200); do
  if curl -sf --max-time 1 "http://127.0.0.1:$port/count" > /dev/null; then break; fi
  sleep 0.1
done

if ! curl -sf --max-time 1 "http://127.0.0.1:$port/count" > /dev/null; then
  echo "the fixture server did not start" >&2
  cat "$work/fixture.err" >&2
  exit 2
fi

bin="$work/models-verify"
mkdir -p "$work/modulecache"
# -disable-sandbox: the Observation macro runs through a plugin server, which the
# compiler's own subprocess sandbox refuses in some environments.
# -module-cache-path: keep the clang module cache next to the build, so a restricted
# temporary directory cannot fail the compile.
xcrun swiftc -O -disable-sandbox -module-cache-path "$work/modulecache" -o "$bin" \
  "$repo/AppleApp/Sources/PlaybackSession/AutomixModelStore.swift" \
  "$here/models-verify/main.swift" || exit 2

MODELS_FIXTURE="http://127.0.0.1:$port" \
MODELS_FIXTURE_DIR="$fixture_dir" \
MODELS_LIVE="${MODELS_LIVE:-0}" \
"$bin"
