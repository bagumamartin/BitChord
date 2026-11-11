# macOS release DMG

The 1.0.0 DMG is unsigned by a developer and is not notarized. The packaging
script ad-hoc signs a staging copy so its nested code has consistent signatures.
The app remains unsandboxed. It retains its source entitlements except for
iCloud Key-Value Store and App Groups, which require a team-signed build. The
app's local lyrics choices, local sign-in, and access to local-library folders
continue to work. Shared iCloud Keychain sessions and the widget's app-group
container are unavailable in this ad-hoc package.

## Build and package

Create an Apple Silicon Release archive without code signing, then copy its app
bundle into a folder named `BitChord.app` inside an export directory:

```sh
xcodebuild \
  -project AppleApp/BitChord.xcodeproj \
  -scheme BitChord \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath "$TMPDIR/BitChord-mac.xcarchive" \
  archive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=

mkdir -p "$TMPDIR/BitChord-mac-export"
ditto "$TMPDIR/BitChord-mac.xcarchive/Products/Applications/BitChord.app" \
  "$TMPDIR/BitChord-mac-export/BitChord.app"
ditto "$TMPDIR/BitChord-mac.xcarchive/dSYMs" "$TMPDIR/BitChord-mac-export/dSYMs"
scripts/package-mac-dmg.sh 1.0.0 "$TMPDIR/BitChord-mac-export"
```

The script refuses an export whose `dSYMs` folder has no match for the app, and
zips the folder beside the DMG. Keep that zip with the release's local files so
a later report can be symbolicated. Do not upload it: it carries local paths.

The script checks the app version, stages a copy, removes provisioning profiles
and old signatures, then ad-hoc signs nested code inside-out without `--deep`.
It retains exactly the source app entitlements except for the restricted iCloud
KVS and App Groups keys. The widget gets its own source entitlements with only
App Groups removed; it remains sandboxed. The app remains unsandboxed. The
script checks the app signature, arm64 slice, Team ID and entitlement payload,
then builds a 1x/2x Finder background,
sets the volume icon and layout, closes and reopens the Finder window to read
back its saved `.DS_Store` state, compresses the DMG, and runs `hdiutil verify`.
The original export is left untouched.

The package script accepts `--output-dir DIR` and requires `--overwrite` to
replace an existing local DMG. GitHub upload and release options remain separate
and ask before changing GitHub; `--create-release` requires an existing pushed
`vVERSION` tag. No tag, signature, notarization, or upload is created by this
local packaging command.

## Open BitChord on macOS

Because the download is not Developer ID signed or notarized, Gatekeeper may
block its first launch. Only continue if you downloaded the DMG from the
official BitChord release and trust it.

1. Drag BitChord to Applications.
2. In Applications, Control-click BitChord and choose **Open**, then confirm
   **Open** in the warning dialog. If that choice is not available, open
   System Settings → Privacy & Security and choose **Open Anyway** for BitChord.

After moving the app to Applications, an informed user can also clear the
quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/BitChord.app"
open "/Applications/BitChord.app"
```

This removes the downloaded-file quarantine attribute; it does not add a
Developer ID signature or notarization.
