# One Apple release

The installed version is always the marketing version **and build number**. `AppleApp/project.yml` is the shared source for both platforms. The next candidate is 1.0.8 (build 17); this does not mean it has been published.

Both files belong to one immutable GitHub release. Use the same source revision, version and build for iOS and Mac. Build from a clean commit and pass `BITCHORD_BUILD_REVISION=$(git rev-parse --short=12 HEAD)` to Xcode; the iOS packaging script stamps this automatically and marks an uncommitted tree `-dirty`.

`scripts/release-apple.sh VERSION` runs steps 1–3 from a clean checkout (native core, shared framework, project, IPA, unsigned Mac archive with its dSYMs, DMG, manifest) into `build/release`. The **Release** GitHub workflow runs the same script on a macOS runner; see `.github/workflows/release.yml`. Release notes live in `release-notes/VERSION.md`.

1. Generate the project and frameworks as usual. Archive the unsigned IPA with `scripts/package-ios-ipa.sh VERSION --output-dir build/release`.
2. Export the Mac Release app with the same build identity and revision, then run `scripts/package-mac-dmg.sh VERSION EXPORT_FOLDER --output-dir build/release`.
3. Run `python3 scripts/prepare-apple-release.py --ipa PATH_TO_IPA --dmg PATH_TO_DMG --output-dir build/release`. This reads the apps' Info.plists, refuses mismatched identities/revisions, and writes `release.json`, `SHA256.txt` and `INSTALL.md` for exactly those two files. It never uploads anything.
4. Attach both installers and these three metadata files to one draft release. Supply notes identifying the fixes and minimum OS versions. Keep old releases available for recovery, but use `/releases/latest` as the single public entry point.
5. Use the existing Sparkle signing workflow to generate the appcast for the **same** Mac build and DMG. Never hand-edit a signed appcast or publish a different file under an existing signed asset name. Verify installation before marking the paired release latest.

The app reads the latest release and its `release.json` to select the right installer. A malformed manifest cannot cause a fallback to an arbitrary file. Legacy releases without a manifest still show their notes and a unique platform installer, but cannot assert equality or offer a same-version update when the published build number is unknown.

Mac updates use Sparkle's download/signature/replace flow. A manual DMG install is the first-install/recovery path. On iOS the user signs the IPA with their existing signing app and identity; downloading an IPA is not an installation. Preserve `app.bitchord.BitChord` and its data rather than uninstalling first.

The existing private build 12 IPA/DMG are not regenerated or relabelled by this change. No release is published by the scripts above unless the separate, explicit publishing options/workflow are invoked.
