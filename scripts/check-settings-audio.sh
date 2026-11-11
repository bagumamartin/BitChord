#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/bitchord-settings-audio.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -module-cache-path "$scratch/modules" -parse-as-library \
  AppleApp/Sources/UI/Settings/AudioSettingsCatalog.swift \
  AppleApp/Sources/UI/ReleaseIdentity.swift scripts/settings-audio-verify/check.swift -o "$scratch/check"
"$scratch/check"
python3 scripts/release-verify/check.py
