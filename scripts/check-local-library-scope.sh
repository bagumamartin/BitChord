#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$scratch/module-cache" \
  "$repo/AppleApp/Sources/PlaybackSession/SecurityScopedResourceLease.swift" \
  "$repo/scripts/local-library-verify/scope.swift" -o "$scratch/check"
"$scratch/check"
