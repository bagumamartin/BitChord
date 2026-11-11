#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <release-tag> <uploaded-dmg> <release-notes.md>" >&2
  exit 2
fi

tag="$1"
dmg_path="$2"
notes_path="$3"
if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tag must look like 0.1.2 or v0.1.2." >&2
  exit 2
fi
if [[ ! -f "$dmg_path" || ! -f "$notes_path" ]]; then
  echo "Both the uploaded DMG and its release-notes Markdown file must exist." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# CI passes SPARKLE_GENERATE_APPCAST (the tool's path) and SPARKLE_ED_KEY_FILE
# (the private EdDSA key exported from the keychain); locally both default to
# Xcode's resolved package and the keychain item under account BitChord.
generate_appcast="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$generate_appcast" ]]; then
  derived_data="$HOME/Library/Developer/Xcode/DerivedData"
  generate_appcast="$(find "$derived_data" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f -print -quit 2>/dev/null || true)"
fi
if [[ -z "$generate_appcast" || ! -x "$generate_appcast" ]]; then
  echo "Sparkle's generate_appcast was not found. Open/resolve AppleApp/BitChord.xcodeproj once in Xcode first." >&2
  exit 1
fi

remote_url="$(git -C "$repo_root" remote get-url origin)"
case "$remote_url" in
  git@*:* )
    remote_host="${remote_url#git@}"
    remote_host="${remote_host%%:*}"
    repository_path="${remote_url#*:}"
    ;;
  ssh://git@*/* )
    remote_host="${remote_url#ssh://git@}"
    remote_host="${remote_host%%/*}"
    repository_path="${remote_url#ssh://git@*/}"
    ;;
  https://*/*|http://*/* )
    remote_host="${remote_url#*://}"
    remote_host="${remote_host%%/*}"
    repository_path="${remote_url#*://*/}"
    ;;
  * )
    echo "Could not determine a GitHub repository URL from origin: $remote_url" >&2
    exit 1
    ;;
esac
repository_path="${repository_path%.git}"
if [[ -z "$remote_host" || -z "$repository_path" ]]; then
  echo "Could not determine a GitHub repository URL from origin: $remote_url" >&2
  exit 1
fi
github_repo_url="https://$remote_host/$repository_path"

archive_name="$(basename "$dmg_path")"
notes_name="${archive_name%.*}.md"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$repo_root/appcast.xml" "$stage/appcast.xml"
cp "$dmg_path" "$stage/$archive_name"
cp "$notes_path" "$stage/$notes_name"

if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  key_args=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
  key_args=(--account BitChord)
fi
"$generate_appcast" \
  "${key_args[@]}" \
  --download-url-prefix "$github_repo_url/releases/download/$tag/" \
  --full-release-notes-url "$github_repo_url/releases/tag/$tag" \
  --embed-release-notes \
  "$stage"

cp "$stage/appcast.xml" "$repo_root/appcast.xml"
echo "Updated $repo_root/appcast.xml for $tag. Commit and push it after the matching DMG is attached to that GitHub release."
