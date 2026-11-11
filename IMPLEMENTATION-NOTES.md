# Listening and interface improvements

Implemented November 11, 2026, with six concurrent GPT-6 Luna workers at high reasoning effort, an additional quality-cap worker, and an independent integration review. Existing work from the initial review was preserved. Spotify's native app was inspected for search, track-menu and queue interactions; BitChord retains its native navigation and visual style.

## Navigation, tracks and queue

- Persistent top-right Search action in browsing and full Now Playing. It dismisses the player before opening and focusing Search.
- Visible liked/not-liked/disliked indicators on song rows, with accessible descriptions. The player, mini player and queue use the existing rating store rather than a separate saved-state system.
- Compact Play Next/Add to Queue actions on Mac hover, iOS swipe actions, context-menu actions, and queue notices.
- Queue search by title/artist, collapsible counted sections, accessible Move Earlier/Later, and Add Music/Find Music actions.
- Filtering preserves the original queue indices for move/delete and the full section indices for drag reordering.
- Spoken scrub position includes total duration. Lyrics rows expose explicit seek/share/reveal actions; hidden player controls retain accessible pane switching.

## Quality and playback

- Highest Available is the existing lossless preference with clear fallback wording. Source Quality compares requested quality with decoded format; the player has a source/format chip opening Audio Pipeline.
- Low and Medium select known formats at or below 64/128 kbps. Selection filters before ranking across direct, cipher and SABR extraction, and capped source responses are validated centrally. If no compliant rendition exists, the request fails rather than exceeding the cap. Bitrate is a data budget, not a cross-codec fidelity score.
- Apply to Current Track re-resolves at the audible playhead and preserves paused/playing intent. Current quality may remain unchanged until that action or another resolution.
- Pause remains available during mini-player buffering. Playback errors have a visible Retry action; source-priority settings explain fallback decisions.
- Repeat-one handoffs validate selected metadata and an armed source before adopting a callback.

## Lyrics

- Fixed incremental matching consuming the following line's observations.
- Provider changes cancel obsolete recognition; stale/canceled callbacks cannot overwrite the active document.
- Typed outcomes distinguish permission, language/model availability, analyzing, partial/full matches, no match, unreadable audio and failure.
- Automatic lookup never opens a Speech permission prompt. Explicit Retry can request permission when undecided, bypasses cache, and reruns alignment.
- Locale candidates include all matching supported variants in deterministic order. Successful alignment has a bounded process-local cache keyed by track/provider/source/document identity.
- Real sung-audio accuracy still requires a device with a supported on-device Speech asset and permission. This machine's English capability probe lacked those assets; no successful real-song recognition is claimed.

## Downloads, imports and reliability

- Downloads separate Active/Failed/Completed, support search and bulk retry with honest network/Wi-Fi feedback, and distinguish saved-download versus stream-cache storage.
- Download byte totals are computed by the background refresh scan. Collection estimates use known data and leave unknown estimates explicit.
- Play saved audio only immediately uses a saved copy or stops with a retryable error, retaining the queue slot. Local/downloaded/cache playback remains available, including next-track preparation. Media prefetch and quality upgrade requests are blocked; unrelated browsing/lyrics services are separate features.
- Cache generations reject stale transfer completions after Clear Cache. Active-reader files are deferred for deletion; republished files are protected from obsolete cleanup.
- Resume signatures include cellular policy, so obsolete resume data is not reused after that policy changes.
- CSV/TSV import shows matching counts and Cancel, limits concurrent catalog matching to four, and rejects inputs above 500 tracks explicitly. Quoted fields, BOM and CRLF are covered. Unmatched tracks remain reviewable.
- Empty device playlists explain file import and local M3U discovery. Settings search announces a debounced result count.
- Library search retains successful categories and shows scoped retries for failed categories. Home pagination has loading/retry feedback. Search rows show album/version information when supplied.
- Folder scope leases balance successful acquisitions and retain access for ongoing scans/playback. Forget Folder releases the selected folder and clears its library view. New Mac bookmarks request security scope.
- Account persistence uses Boolean writes and availability-aware readback, preventing an unavailable Keychain read from proving a failed deletion succeeded.
- Restored the missing release-note display sanitizer used by the existing verification suite. New English UI keys were registered in the localization catalog; translations were preserved.

## Verification

- Full macOS Debug app build: passed.
- Full iPhone/iPad Simulator Debug app build: passed.
- Kotlin/Native macOS suites: 997 shared tests and 260 extractor tests passed, zero failures.
- Standalone queue suite: 116 checks plus source contracts passed.
- Playlist import, lyrics-state/locale, offline/cache/resume/retry, folder-scope, settings/audio, release and settings-parity checks: passed.
- Interactive isolated Mac app: verified Search navigation, search results with rating indicators, queue action menu and confirmation, queue panel and title filtering. The temporary app used the debug validation identity; no account sign-in or rating change was performed.
- Mac controller/runtime suite: 38 checks passed, including quality changes at the current position and offline transitions.

Build caches and generated frameworks/projects remain local ignored artifacts. The existing installed application was not replaced.
