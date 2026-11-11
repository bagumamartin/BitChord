#!/usr/bin/env bash
# Build one Apple release from a clean checkout: the unsigned IPA, the ad-hoc
# signed Mac DMG with its dSYMs, and release.json / SHA256.txt / INSTALL.md.
# The same script runs on a developer Mac and on the GitHub release workflow.
# It never uploads anything; publishing is a separate, explicit step.
#
# Usage: scripts/release-apple.sh <version> [--output-dir DIR] [--skip-prereqs]
#
# --skip-prereqs reuses the native core, shared framework and Xcode project
# already generated in this checkout instead of rebuilding them.
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
version="$1"; shift
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'version must look like 1.0.0'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$repo_root/build/release"
skip_prereqs=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || fail '--output-dir needs a path'; output_dir="$2"; shift 2 ;;
    --skip-prereqs) skip_prereqs=1; shift ;;
    *) fail "Unknown option: $1" ;;
  esac
done

cd "$repo_root"
spec_version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' AppleApp/project.yml | head -1)"
spec_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' AppleApp/project.yml | head -1)"
[[ "$spec_version" == "$version" ]] || fail "AppleApp/project.yml says $spec_version, not $version"
[[ "$spec_build" =~ ^[0-9]+$ ]] || fail 'AppleApp/project.yml has no numeric CURRENT_PROJECT_VERSION'
if ! git diff --quiet HEAD -- || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  fail 'the working tree has uncommitted changes; a release is built from a clean commit'
fi
revision="$(git rev-parse --short=12 HEAD)"
printf 'Building BitChord %s (build %s) at %s\n' "$version" "$spec_build" "$revision"

if [[ "$skip_prereqs" -eq 0 ]]; then
  # Device slices only: a release never runs in the Simulator.
  NATIVE_TARGETS="aarch64-apple-darwin aarch64-apple-ios" scripts/build-native-core.sh
  CONFIG=release scripts/build-shared-framework.sh
  (cd AppleApp && xcodegen generate --spec project.yml)
fi
[[ -d AppleApp/BitChord.xcodeproj ]] || fail 'AppleApp/BitChord.xcodeproj is missing; run without --skip-prereqs'

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work="$repo_root/build/release-work"
rm -rf "$work"
mkdir -p "$work"

BITCHORD_BUILD_REVISION="$revision" scripts/package-ios-ipa.sh "$version" --output-dir "$output_dir" --overwrite

archive="$work/BitChord-mac.xcarchive"
xcodebuild \
  -project AppleApp/BitChord.xcodeproj \
  -scheme BitChord \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$work/DerivedData-mac" \
  archive \
  BITCHORD_BUILD_REVISION="$revision" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=
export_dir="$work/mac-export"
mkdir -p "$export_dir"
ditto "$archive/Products/Applications/BitChord.app" "$export_dir/BitChord.app"
ditto "$archive/dSYMs" "$export_dir/dSYMs"
scripts/package-mac-dmg.sh "$version" "$export_dir" --output-dir "$output_dir" --overwrite

ipa="$output_dir/BitChord-$version-build$spec_build-ios-unsigned.ipa"
dmg="$output_dir/BitChord-$version-build$spec_build-mac-arm64.dmg"
[[ -f "$ipa" ]] || fail "expected IPA not found: $ipa"
[[ -f "$dmg" ]] || fail "expected DMG not found: $dmg"
python3 scripts/prepare-apple-release.py --ipa "$ipa" --dmg "$dmg" --output-dir "$output_dir"

rm -rf "$work"
printf '\nRelease files in %s:\n' "$output_dir"
for f in "$ipa" "$dmg" "$output_dir/release.json" "$output_dir/SHA256.txt" "$output_dir/INSTALL.md"; do
  printf '  %s\n' "$(basename "$f")"
done
