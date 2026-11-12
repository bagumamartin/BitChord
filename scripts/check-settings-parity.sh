#!/bin/bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
require() {
  local file="$1" pattern="$2"
  if ! grep -Fq "$pattern" "$repo/$file"; then
    echo "missing settings parity contract: $file: $pattern" >&2
    exit 1
  fi
}

require AppleApp/Sources/UI/Settings/SettingsView+Playback.swift 'rows.row("Phrase Length"'
require AppleApp/Sources/UI/Settings/SettingsView+Playback.swift 'controller.setAutomixPhraseBars($0)'
require AppleApp/Sources/UI/Settings/SettingsView+Playback.swift 'Text("Adaptive").tag(0)'
require AppleApp/Sources/UI/Settings/SettingsView+Playback.swift 'Text("8 bars").tag(8)'
require AppleApp/Sources/UI/Settings/SettingsView+Playback.swift 'Text("16 bars").tag(16)'
require AppleApp/Sources/App/SettingsDeepLink.swift 'url.host?.lowercased() == "settings"'
require AppleApp/Sources/App/SettingsDeepLink.swift '?? SettingsView.SettingsSection.account.rawValue'
require AppleApp/Sources/App/SettingsDeepLink.swift 'openSettings()'
require AppleApp/Sources/UI/Settings/SettingsView.swift 'proxy.scrollTo(section, anchor: .top)'
require AppleApp/Sources/UI/Settings/AudioSettingsCatalog.swift 'return "Loudness Normalization"'
require AppleApp/Sources/UI/Settings/AudioSettingsPageView.swift 'SettingsSubToggle(title: "Off on iPhone Speaker"'
require AppleApp/Sources/UI/Settings/AudioSettingsPageView.swift 'Text("Track").tag("TRACK")'
require AppleApp/Sources/UI/Settings/AudioSettingsPageView.swift 'Text("Album").tag("ALBUM")'
require AppleApp/Sources/UI/Settings/SettingsView.swift 'controller.updateLoudnessMode(controller.loudnessMode)'
require AppleApp/Sources/UI/Settings/SettingsView.swift 'private var macSettingsSplitView: some View'
require AppleApp/Sources/UI/Settings/SettingsMacSplitView.swift 'NavigationSplitView'
require AppleApp/Sources/UI/Settings/SettingsMacSplitView.swift '.navigationSplitViewColumnWidth(min: 190, ideal: 240)'
require AppleApp/Sources/UI/Settings/SettingsPersistence.swift 'value ? loudnessModeSelection : "OFF"'
require AppleApp/Sources/UI/Settings/SettingsView+About.swift 'rows.row("Hide Status Bar in Player"'
require AppleApp/Sources/UI/Settings/SettingsView+About.swift 'rows.row("Show Queue History"'
require AppleApp/Sources/UI/Settings/SettingsView+About.swift 'rows.row("Stop Music on Close"'
require AppleApp/Sources/UI/Settings/SettingsView+Storage.swift 'rows.row("Show Cached Songs in Library"'
require AppleApp/Sources/UI/Settings/SettingsView+Appearance.swift 'rows.row("Artist Signatures"'
require AppleApp/Sources/UI/Settings/SettingsView+Appearance.swift 'AppSettings.shared.setArtistSignaturesEnabled(value: value)'
require AppleApp/Sources/UI/Settings/SettingsView+Appearance.swift 'AppSettings.shared.setArtistSignaturesWikimediaUrl(value: value)'
require AppleApp/Sources/UI/NowPlaying/NowPlayingView.swift '.statusBarHidden(hideStatusBarInPlayer)'
require AppleApp/Sources/UI/NowPlaying/UpNextPane.swift 'sectionHeader("Previously Played"'
require AppleApp/Sources/UI/SourcesView.swift 'Text("Track Length Tolerance")'
require shared/src/commonMain/kotlin/com/music/bitchord/data/settings/AppSettings.kt 'fun setUpgradeLengthSlackSeconds(value: Int)'
require shared/src/commonMain/kotlin/com/music/bitchord/data/settings/AppSettings.kt 'KEY_UPGRADE_LENGTH_SLACK_SECONDS'
require shared/src/commonTest/kotlin/com/music/bitchord/data/settings/UpgradeLengthSlackTest.kt 'slack is bounded persisted and included in settings backup'
require shared/src/commonTest/kotlin/com/music/bitchord/data/settings/UpgradeLengthSlackTest.kt 'artist signature preferences persist and restore'
require AppleApp/Sources/UI/SearchView.swift 'typeaheadMaxResults = 15'
require AppleApp/Sources/UI/SearchView.swift 'TYPEAHEAD_MAX_RESULTS'
require AppleApp/Sources/UI/SearchView.swift 'typeaheadHits.prefix(Self.typeaheadMaxResults)'

echo "settings parity source contracts passed"
