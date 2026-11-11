#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun swiftc -swift-version 5 -module-cache-path "$work/modules" -parse-as-library -o "$work/playlist-import-check" \
  "$repo/scripts/playlist-import-verify/Stubs.swift" \
  "$repo/AppleApp/Sources/PlaybackSession/PlaylistFileImport.swift" \
  "$repo/scripts/playlist-import-verify/main.swift"
"$work/playlist-import-check"

cat > "$work/accessibility-check.swift" <<'SWIFT'
import SwiftUI
#if os(iOS)
import UIKit
func announce(_ message: String) {
    UIAccessibility.post(notification: .announcement, argument: message)
}
#else
import AppKit
func announce(_ message: String) {
    NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ]
    )
}
#endif
SWIFT

xcrun swiftc -module-cache-path "$work/modules" -typecheck "$work/accessibility-check.swift"
xcrun swiftc -module-cache-path "$work/modules" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios18.0-simulator -typecheck "$work/accessibility-check.swift"
