package com.music.bitchord.data.settings

import kotlinx.serialization.json.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import com.music.bitchord.data.library.LocalMusicSort
import com.music.bitchord.data.library.LocalViewType
import com.music.bitchord.data.lyrics.LyricsSource
import com.music.bitchord.data.lyrics.normalizePaxSenixApiKey
import com.music.bitchord.data.remote.WebDavConfig

/** Providers enabled for a fresh install; explicit saved choices are handled separately. */
internal fun defaultEnabledLyricsSources(): Set<LyricsSource> =
    LyricsSource.entries.filter { it != LyricsSource.SIMP_MUSIC }.toSet()

/**
 * The stream ceiling for a connection, and — via [permits] — which sources that
 * ceiling is willing to pay for.
 *
 * [LOSSLESS] is a rung rather than a boolean because it is a *stream* ceiling,
 * distinct from [DownloadQuality]'s: a file saved to the device is paid for once
 * and kept forever, whereas a stream is bytes spent again on every replay. The
 * two therefore have independent settings, and conflating them is what made the
 * port unable to express "lossless when I'm on Wi-Fi" at all.
 */
enum class SoundMode { TRANSPARENT, ENHANCED }
enum class ClarityPreset { REFERENCE, SPEAKER, HEADPHONE, DAC }
enum class LoudnessMode { OFF, TRACK, ALBUM }
data class ClarityTuning(val preset: ClarityPreset = ClarityPreset.REFERENCE, val wet: Float = 1f, val trimsDb: List<Float> = List(8) { 0f })

enum class AudioQuality(val maxKbps: Int, val label: String) {
    LOW(64, "Low"),
    MEDIUM(128, "Medium"),
    HIGH(Int.MAX_VALUE, "High"),
    LOSSLESS(Int.MAX_VALUE, "Lossless"),
    ;

    /**
     * Whether a source of this kind is worth asking at this ceiling.
     *
     * The mechanism that decides which sources may answer before YouTube on a
     * given connection, and it is a property of the *ceiling* rather than of the
     * source: at [LOW] and [MEDIUM] there is no point asking an addon to search
     * its catalogue for a FLAC, because the answer would be transcoded down to
     * something JioSaavn already has, and the search is the expensive part. At
     * [HIGH] the addon is worth a look; at [LOSSLESS] it is the only thing that
     * can answer at all.
     */
    fun permits(kind: com.music.bitchord.data.sources.SourceKind): Boolean = when (this) {
        LOW, MEDIUM -> kind == com.music.bitchord.data.sources.SourceKind.YOUTUBE
        HIGH -> !kind.canServeLossless
        LOSSLESS -> true
    }

    companion object {
        fun fromName(raw: String): AudioQuality =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: LOSSLESS
    }
}

enum class DownloadQuality(val maxKbps: Int, val keepsLossless: Boolean, val label: String) {
    STANDARD(128, false, "Standard"),
    HIGH(Int.MAX_VALUE, false, "High"),
    LOSSLESS(Int.MAX_VALUE, true, "Lossless"),
    ;

    companion object {
        fun fromName(raw: String): DownloadQuality =
            entries.firstOrNull { it.name.equals(raw, ignoreCase = true) } ?: LOSSLESS
    }
}

/**
 * The signed-in account, as far as the settings tier needs to describe it.
 *
 * Only what one feature asked for, which is the point: a party needs a name to call
 * somebody and a face to put beside it, and holding the rest of an account in a
 * process-wide cache to serve that would be more account in memory than the app
 * needs to be holding.
 */
data class PartyAccount(
    val name: String,
    val email: String,
    val avatarUrl: String?,
)

/**
 * Port of upstream `data/settings/AppSettings.kt`. Keys match Android so a
 * settings dump is readable across ports. Backed by [PlatformSettings].
 */
object AppSettings {

    private val settings = PlatformSettings

    private const val KEY_LISTEN_SERVER = "listen_together_server"
    private const val KEY_LISTEN_NICKNAME = "listen_together_nickname"

    // The same key names upstream uses, so a settings dump reads the same across ports.
    private const val KEY_WEBDAV_URL = "webdav_url"
    private const val KEY_WEBDAV_USERNAME = "webdav_username"
    private const val KEY_WEBDAV_PASSWORD = "webdav_password"
    private const val KEY_UPGRADE_LENGTH_SLACK_SECONDS = "upgrade_length_slack_seconds"

    /**
     * The longest nickname stored.
     *
     * Bounded on the way in rather than on the way out, because the name is sent to
     * every other device in the party and rendered in a list row on each of them.
     */
    private const val MAX_NICKNAME_LENGTH = 48

    // ---- Playback ----------------------------------------------------------
    private val _crossfadeSeconds = MutableStateFlow(settings.getInt("crossfade_seconds", 0))
    val crossfadeSeconds: StateFlow<Int> = _crossfadeSeconds.asStateFlow()
    fun setCrossfadeSeconds(value: Int) {
        _crossfadeSeconds.value = value.coerceIn(0, 12)
        settings.putInt("crossfade_seconds", _crossfadeSeconds.value)
    }

    private val _smartFadeEnabled = MutableStateFlow(settings.getBoolean("smart_fade_enabled", true))
    val smartFadeEnabled: StateFlow<Boolean> = _smartFadeEnabled.asStateFlow()
    fun setSmartFadeEnabled(value: Boolean) {
        _smartFadeEnabled.value = value
        settings.putBoolean("smart_fade_enabled", value)
    }

    private val _spatialAudio = MutableStateFlow(settings.getBoolean("spatial_audio", false))
    val spatialAudio: StateFlow<Boolean> = _spatialAudio.asStateFlow()
    fun setSpatialAudio(value: Boolean) {
        _spatialAudio.value = value
        settings.putBoolean("spatial_audio", value)
    }

    private val _autoplay = MutableStateFlow(settings.getBoolean("autoplay", true))
    val autoplay: StateFlow<Boolean> = _autoplay.asStateFlow()
    fun setAutoplay(value: Boolean) {
        _autoplay.value = value
        settings.putBoolean("autoplay", value)
    }

    private val _skipSilence = MutableStateFlow(settings.getBoolean("skip_silence", false))
    val skipSilence: StateFlow<Boolean> = _skipSilence.asStateFlow()
    fun setSkipSilence(value: Boolean) {
        _skipSilence.value = value
        settings.putBoolean("skip_silence", value)
    }

    private val _playbackSpeed = MutableStateFlow(settings.getFloat("playback_speed", 1.0f))
    val playbackSpeed: StateFlow<Float> = _playbackSpeed.asStateFlow()
    fun setPlaybackSpeed(value: Float) {
        _playbackSpeed.value = value.coerceIn(0.5f, 2.0f)
        settings.putFloat("playback_speed", _playbackSpeed.value)
    }

    private val _audioQualityWifi = MutableStateFlow(
        AudioQuality.fromName(settings.getString("audio_quality_wifi", "LOSSLESS")),
    )
    val audioQualityWifi: StateFlow<AudioQuality> = _audioQualityWifi.asStateFlow()
    fun setAudioQualityWifi(value: String) {
        val q = AudioQuality.fromName(value)
        _audioQualityWifi.value = q
        settings.putString("audio_quality_wifi", q.name)
    }

    private val _audioQualityCellular = MutableStateFlow(
        AudioQuality.fromName(settings.getString("audio_quality_cellular", "LOSSLESS")),
    )
    val audioQualityCellular: StateFlow<AudioQuality> = _audioQualityCellular.asStateFlow()
    fun setAudioQualityCellular(value: String) {
        val q = AudioQuality.fromName(value)
        _audioQualityCellular.value = q
        settings.putString("audio_quality_cellular", q.name)
    }

    private val _downloadQuality = MutableStateFlow(
        DownloadQuality.fromName(settings.getString("download_quality", "LOSSLESS")),
    )
    val downloadQuality: StateFlow<DownloadQuality> = _downloadQuality.asStateFlow()
    fun setDownloadQuality(value: String) {
        val q = DownloadQuality.fromName(value)
        _downloadQuality.value = q
        settings.putString("download_quality", q.name)
    }

    private val _wifiOnlyDownloads = MutableStateFlow(settings.getBoolean("wifi_only_downloads", true))
    val wifiOnlyDownloads: StateFlow<Boolean> = _wifiOnlyDownloads.asStateFlow()
    fun setWifiOnlyDownloads(value: Boolean) {
        _wifiOnlyDownloads.value = value
        settings.putBoolean("wifi_only_downloads", value)
    }

    private val _showNerdStats = MutableStateFlow(settings.getBoolean("show_nerd_stats", false))
    val showNerdStats: StateFlow<Boolean> = _showNerdStats.asStateFlow()
    fun setShowNerdStats(value: Boolean) {
        _showNerdStats.value = value
        settings.putBoolean("show_nerd_stats", value)
    }

    private val _animatedCanvas = MutableStateFlow(settings.getBoolean("animated_canvas", true))
    val animatedCanvas: StateFlow<Boolean> = _animatedCanvas.asStateFlow()
    fun setAnimatedCanvas(value: Boolean) {
        _animatedCanvas.value = value
        settings.putBoolean("animated_canvas", value)
    }

    private val _canvasOverCellular = MutableStateFlow(settings.getBoolean("canvas_over_cellular", false))
    val canvasOverCellular: StateFlow<Boolean> = _canvasOverCellular.asStateFlow()
    fun setCanvasOverCellular(value: Boolean) {
        _canvasOverCellular.value = value
        settings.putBoolean("canvas_over_cellular", value)
    }

    private val _prioritizeSpotifyCanvas = MutableStateFlow(
        settings.getBoolean("prioritize_spotify_canvas", false),
    )
    val prioritizeSpotifyCanvas: StateFlow<Boolean> = _prioritizeSpotifyCanvas.asStateFlow()
    fun setPrioritizeSpotifyCanvas(value: Boolean) {
        _prioritizeSpotifyCanvas.value = value
        settings.putBoolean("prioritize_spotify_canvas", value)
    }

    // ---- Appearance --------------------------------------------------------
    private val _themeMode = MutableStateFlow(settings.getString("theme_mode", "dark"))
    val themeMode: StateFlow<String> = _themeMode.asStateFlow()
    fun setThemeMode(value: String) {
        _themeMode.value = value
        settings.putString("theme_mode", value)
    }

    private val _reduceDynamicBlur = MutableStateFlow(settings.getBoolean("reduce_dynamic_blur", false))
    val reduceDynamicBlur: StateFlow<Boolean> = _reduceDynamicBlur.asStateFlow()
    fun setReduceDynamicBlur(value: Boolean) {
        _reduceDynamicBlur.value = value
        settings.putBoolean("reduce_dynamic_blur", value)
    }

    private val _reduceAnimation = MutableStateFlow(settings.getBoolean("reduce_animation", false))
    val reduceAnimation: StateFlow<Boolean> = _reduceAnimation.asStateFlow()
    fun setReduceAnimation(value: Boolean) {
        _reduceAnimation.value = value
        settings.putBoolean("reduce_animation", value)
    }

    private val _fullBleedArtwork = MutableStateFlow(settings.getBoolean("full_bleed_artwork", true))
    val fullBleedArtwork: StateFlow<Boolean> = _fullBleedArtwork.asStateFlow()
    fun setFullBleedArtwork(value: Boolean) {
        _fullBleedArtwork.value = value
        settings.putBoolean("full_bleed_artwork", value)
    }

    private val _dolbyAtmos = MutableStateFlow(settings.getBoolean("dolby_atmos", true))
    val dolbyAtmos: StateFlow<Boolean> = _dolbyAtmos.asStateFlow()
    fun setDolbyAtmos(value: Boolean) { _dolbyAtmos.value = value; settings.putBoolean("dolby_atmos", value) }

    private val _lyricsBlur = MutableStateFlow(settings.getBoolean("lyrics_blur", true))
    val lyricsBlur: StateFlow<Boolean> = _lyricsBlur.asStateFlow()
    fun setLyricsBlur(value: Boolean) { _lyricsBlur.value = value; settings.putBoolean("lyrics_blur", value) }
    private val _translationLanguage = MutableStateFlow(settings.getString("translation_language", ""))
    val translationLanguage: StateFlow<String> = _translationLanguage.asStateFlow()
    fun setTranslationLanguage(value: String) { _translationLanguage.value = value; settings.putString("translation_language", value) }

    private val _syncedLyrics = MutableStateFlow(settings.getBoolean("synced_lyrics", true))
    val syncedLyrics: StateFlow<Boolean> = _syncedLyrics.asStateFlow()
    fun setSyncedLyrics(value: Boolean) {
        _syncedLyrics.value = value
        settings.putBoolean("synced_lyrics", value)
    }

    private val _convertVideoToAudio = MutableStateFlow(settings.getBoolean("convert_video_to_audio", true))
    val convertVideoToAudio: StateFlow<Boolean> = _convertVideoToAudio.asStateFlow()
    fun setConvertVideoToAudio(value: Boolean) {
        _convertVideoToAudio.value = value
        settings.putBoolean("convert_video_to_audio", value)
    }

    private val _swipeToPlayNext = MutableStateFlow(settings.getBoolean("swipe_to_play_next", false))
    val swipeToPlayNext: StateFlow<Boolean> = _swipeToPlayNext.asStateFlow()
    fun setSwipeToPlayNext(value: Boolean) {
        _swipeToPlayNext.value = value
        settings.putBoolean("swipe_to_play_next", value)
    }

    private val _dontRepeatSuggestions = MutableStateFlow(settings.getBoolean("dont_repeat_suggestions", false))
    val dontRepeatSuggestions: StateFlow<Boolean> = _dontRepeatSuggestions.asStateFlow()
    fun setDontRepeatSuggestions(value: Boolean) {
        _dontRepeatSuggestions.value = value
        settings.putBoolean("dont_repeat_suggestions", value)
    }

    private val _hideVolumeBar = MutableStateFlow(settings.getBoolean("hide_volume_bar", false))
    val hideVolumeBar: StateFlow<Boolean> = _hideVolumeBar.asStateFlow()
    fun setHideVolumeBar(value: Boolean) {
        _hideVolumeBar.value = value
        settings.putBoolean("hide_volume_bar", value)
    }

    private val _lyricsSources = MutableStateFlow(readLyricsSourcesPref())
    val lyricsSources: StateFlow<String> = _lyricsSources.asStateFlow()
    fun setLyricsSources(value: String) {
        val stored = persistLyricsSources(value)
        _lyricsSources.value = stored
        settings.putString("lyrics_sources", stored)
    }

    private val _lyricsSourceOrder = MutableStateFlow(readLyricsSourceOrderPref())
    val lyricsSourceOrder: StateFlow<String> = _lyricsSourceOrder.asStateFlow()
    fun setLyricsSourceOrder(value: String) {
        val stored = persistLyricsSourceOrder(value)
        _lyricsSourceOrder.value = stored
        settings.putString("lyrics_source_order", stored)
    }

    fun lyricsSourcesSet(): Set<LyricsSource> = parseLyricsSources(_lyricsSources.value)

    fun lyricsSourceOrderList(): List<LyricsSource> = parseLyricsSourceOrder(_lyricsSourceOrder.value)

    /** JSON array of sources in current order, for the Swift settings UI. */
    fun lyricsSourceCatalogJson(): String {
        val enabled = lyricsSourcesSet()
        return lyricsSourceOrderList().joinToString(",", prefix = "[", postfix = "]") { src ->
            """{"name":"${src.name}","label":${jsonString(src.label)},"detail":${jsonString(src.detail)},"wordSynced":${src.wordSynced},"enabled":${src in enabled}}"""
        }
    }

    fun resetLyricsSourceSettings() {
        setLyricsSources(defaultLyricsSourcesJoined())
        setLyricsSourceOrder(defaultLyricsSourcesJoined())
        setPrioritizeSyllableSync(false)
    }

    /** The "Unlimited" cache setting: a ceiling no disk will ever reach. */
    const val UNLIMITED_CACHE_LIMIT_BYTES = Long.MAX_VALUE

    private val _audioCacheLimitBytes = MutableStateFlow(
        settings.getLong("audio_cache_limit_bytes", DEFAULT_CACHE_LIMIT_BYTES)
            .coerceCacheLimit(),
    )
    val audioCacheLimitBytes: StateFlow<Long> = _audioCacheLimitBytes.asStateFlow()
    fun setAudioCacheLimitBytes(value: Long) {
        _audioCacheLimitBytes.value = value.coerceCacheLimit()
        settings.putLong("audio_cache_limit_bytes", _audioCacheLimitBytes.value)
    }

    /**
     * A cache limit inside the allowed range — or the unlimited sentinel.
     *
     * Unlimited has to survive the clamp, which is why it is checked first:
     * coercing `Long.MAX_VALUE` back to the 10 GB ceiling would silently turn
     * "Unlimited" into "10 GB".
     */
    private fun Long.coerceCacheLimit(): Long =
        if (this >= UNLIMITED_CACHE_LIMIT_BYTES) UNLIMITED_CACHE_LIMIT_BYTES
        else coerceIn(DEFAULT_CACHE_LIMIT_BYTES, MAX_CACHE_LIMIT_BYTES)

    // ---- Local library -----------------------------------------------------
    private val _localLibraryPath = MutableStateFlow(settings.getString("local_library_path", ""))
    val localLibraryPath: StateFlow<String> = _localLibraryPath.asStateFlow()
    fun setLocalLibraryPath(value: String) {
        _localLibraryPath.value = value
        settings.putString("local_library_path", value)
    }

    /**
     * How a scanned local library is ordered.
     *
     * Defaults to [LocalMusicSort.TITLE_ASC] because a scan arrives in whatever
     * order the file system enumerated it, and that order is not something anyone
     * chose. Persisted app-wide rather than per screen: one choice, kept until
     * another is made.
     */
    private val _localLibrarySort = MutableStateFlow(
        parseLocalSort(settings.getString("local_library_sort", "")),
    )
    val localLibrarySort: StateFlow<LocalMusicSort> = _localLibrarySort.asStateFlow()

    fun setLocalLibrarySort(value: LocalMusicSort) {
        _localLibrarySort.value = value
        settings.putString("local_library_sort", value.name)
    }

    /** List or grid. Defaults to [LocalViewType.LIST]. */
    private val _localLibraryViewType = MutableStateFlow(
        parseLocalViewType(settings.getString("local_library_view_type", "")),
    )
    val localLibraryViewType: StateFlow<LocalViewType> = _localLibraryViewType.asStateFlow()

    fun setLocalLibraryViewType(value: LocalViewType) {
        _localLibraryViewType.value = value
        settings.putString("local_library_view_type", value.name)
    }

    // An unreadable stored value falls back rather than throwing: these are
    // preferences, and a preference that cannot be parsed is a preference that
    // was never worth failing a launch over.
    private fun parseLocalSort(name: String): LocalMusicSort =
        LocalMusicSort.entries.firstOrNull { it.name == name } ?: LocalMusicSort.TITLE_ASC

    private fun parseLocalViewType(name: String): LocalViewType =
        LocalViewType.entries.firstOrNull { it.name == name } ?: LocalViewType.LIST

    // ---- PaxSenix ----------------------------------------------------------

    /**
     * The proxy key for the authenticated PaxSeniX routes.
     *
     * A bearer credential, so it goes to the secret tier — the same treatment as
     * the scrobbling tokens. Readable from the settings *list* as well, so a value
     * written before the split still works.
     */
    private val _paxSenixApiKey = MutableStateFlow(settings.getSecret("paxsenix_api_key").orEmpty())
    val paxSenixApiKey: StateFlow<String> = _paxSenixApiKey.asStateFlow()

    fun setPaxSenixApiKey(value: String) {
        val normalized = normalizePaxSenixApiKey(value)
        _paxSenixApiKey.value = normalized
        settings.putSecret("paxsenix_api_key", normalized.ifEmpty { null })
    }

    // ---- Sources -----------------------------------------------------------
    private val _moduleIndexUrl = MutableStateFlow(settings.getString("module_index_url", ""))
    val moduleIndexUrl: StateFlow<String> = _moduleIndexUrl.asStateFlow()
    fun setModuleIndexUrl(value: String) {
        _moduleIndexUrl.value = value.trim()
        settings.putString("module_index_url", _moduleIndexUrl.value)
    }

    private val _customSourceUrl = MutableStateFlow(settings.getString("custom_source_url", ""))
    val customSourceUrl: StateFlow<String> = _customSourceUrl.asStateFlow()
    fun setCustomSourceUrl(value: String) {
        _customSourceUrl.value = value.trim()
        settings.putString("custom_source_url", _customSourceUrl.value)
    }

    private val _eqGains = MutableStateFlow(settings.getString("eq_gains", "0,0,0,0,0,0,0,0,0,0"))
    val eqGains: StateFlow<String> = _eqGains.asStateFlow()
    fun setEqGains(value: String) {
        _eqGains.value = value
        settings.putString("eq_gains", value)
    }

    // ---- Scrobbling --------------------------------------------------------
    private val _lastFmApiKey = MutableStateFlow(settings.getSecret("lastfm_api_key").orEmpty())
    val lastFmApiKey: StateFlow<String> = _lastFmApiKey.asStateFlow()
    fun setLastFmApiKey(value: String) {
        _lastFmApiKey.value = value.trim()
        settings.putSecret("lastfm_api_key", _lastFmApiKey.value.ifEmpty { null })
    }

    private val _lastFmSecret = MutableStateFlow(settings.getSecret("lastfm_secret").orEmpty())
    val lastFmSecret: StateFlow<String> = _lastFmSecret.asStateFlow()
    fun setLastFmSecret(value: String) {
        _lastFmSecret.value = value.trim()
        settings.putSecret("lastfm_secret", _lastFmSecret.value.ifEmpty { null })
    }

    private val _lastFmSession = MutableStateFlow(settings.getSecret("lastfm_session").orEmpty())
    val lastFmSession: StateFlow<String> = _lastFmSession.asStateFlow()
    fun setLastFmSession(value: String) {
        _lastFmSession.value = value.trim()
        settings.putSecret("lastfm_session", _lastFmSession.value.ifEmpty { null })
    }

    private val _lastFmUsername = MutableStateFlow(settings.getString("lastfm_username", ""))
    val lastFmUsername: StateFlow<String> = _lastFmUsername.asStateFlow()
    fun setLastFmUsername(value: String) {
        _lastFmUsername.value = value.trim()
        settings.putString("lastfm_username", _lastFmUsername.value)
    }

    private val _lastFmEnabled = MutableStateFlow(settings.getBoolean("lastfm_enabled", false))
    val lastFmEnabled: StateFlow<Boolean> = _lastFmEnabled.asStateFlow()
    fun setLastFmEnabled(value: Boolean) {
        _lastFmEnabled.value = value
        settings.putBoolean("lastfm_enabled", value)
    }

    private val _lastFmScrobble = MutableStateFlow(settings.getBoolean("lastfm_scrobble", true))
    val lastFmScrobble: StateFlow<Boolean> = _lastFmScrobble.asStateFlow()
    fun setLastFmScrobble(value: Boolean) {
        _lastFmScrobble.value = value
        settings.putBoolean("lastfm_scrobble", value)
    }

    private val _lastFmNowPlaying = MutableStateFlow(settings.getBoolean("lastfm_nowplaying", true))
    val lastFmNowPlaying: StateFlow<Boolean> = _lastFmNowPlaying.asStateFlow()
    fun setLastFmNowPlaying(value: Boolean) {
        _lastFmNowPlaying.value = value
        settings.putBoolean("lastfm_nowplaying", value)
    }

    private val _listenBrainzToken = MutableStateFlow(settings.getSecret("listenbrainz_token").orEmpty())
    val listenBrainzToken: StateFlow<String> = _listenBrainzToken.asStateFlow()
    fun setListenBrainzToken(value: String) {
        _listenBrainzToken.value = value.trim()
        settings.putSecret("listenbrainz_token", _listenBrainzToken.value.ifEmpty { null })
    }

    private val _listenBrainzEnabled = MutableStateFlow(settings.getBoolean("listenbrainz_enabled", false))
    val listenBrainzEnabled: StateFlow<Boolean> = _listenBrainzEnabled.asStateFlow()
    fun setListenBrainzEnabled(value: Boolean) {
        _listenBrainzEnabled.value = value
        settings.putBoolean("listenbrainz_enabled", value)
    }

    // ---- Discord -----------------------------------------------------------
    /**
     * Read from the secret tier, not the settings list.
     *
     * A Discord token is a bearer credential: anything holding it can post as
     * the listener. In the settings list it was plain text in `NSUserDefaults`,
     * which means it travelled in every iCloud backup and sat in the preferences
     * plist — where `exportPrefsJson` is careful to leave it out, but which is
     * still readable by anything with the container.
     */
    private val _discordToken = MutableStateFlow(settings.getSecret("discord_token").orEmpty())
    val discordToken: StateFlow<String> = _discordToken.asStateFlow()
    fun setDiscordToken(value: String) {
        _discordToken.value = value.trim()
        settings.putSecret("discord_token", _discordToken.value.ifEmpty { null })
    }

    private val _discordUsername = MutableStateFlow(settings.getString("discord_username", ""))
    val discordUsername: StateFlow<String> = _discordUsername.asStateFlow()
    fun setDiscordUsername(value: String) {
        _discordUsername.value = value.trim()
        settings.putString("discord_username", _discordUsername.value)
    }

    private val _discordRpcEnabled = MutableStateFlow(settings.getBoolean("discord_rpc_enabled", true))
    val discordRpcEnabled: StateFlow<Boolean> = _discordRpcEnabled.asStateFlow()
    fun setDiscordRpcEnabled(value: Boolean) {
        _discordRpcEnabled.value = value
        settings.putBoolean("discord_rpc_enabled", value)
    }

    private val _discordStatus = MutableStateFlow(settings.getString("discord_status", "online"))
    val discordStatus: StateFlow<String> = _discordStatus.asStateFlow()
    fun setDiscordStatus(value: String) {
        _discordStatus.value = value
        settings.putString("discord_status", value)
    }

    private val _discordActivityType = MutableStateFlow(settings.getString("discord_activity_type", "listening"))
    val discordActivityType: StateFlow<String> = _discordActivityType.asStateFlow()
    fun setDiscordActivityType(value: String) {
        _discordActivityType.value = value
        settings.putString("discord_activity_type", value)
    }

    private val _discordActivityName = MutableStateFlow(settings.getString("discord_activity_name", ""))
    val discordActivityName: StateFlow<String> = _discordActivityName.asStateFlow()
    fun setDiscordActivityName(value: String) {
        _discordActivityName.value = value
        settings.putString("discord_activity_name", value)
    }

    private val _discordSwapTitle = MutableStateFlow(settings.getBoolean("discord_swap_title", false))
    val discordSwapTitle: StateFlow<Boolean> = _discordSwapTitle.asStateFlow()
    fun setDiscordSwapTitle(value: Boolean) {
        _discordSwapTitle.value = value
        settings.putBoolean("discord_swap_title", value)
    }

    private val _discordUseDetails = MutableStateFlow(settings.getBoolean("discord_use_details", false))
    val discordUseDetails: StateFlow<Boolean> = _discordUseDetails.asStateFlow()
    fun setDiscordUseDetails(value: Boolean) {
        _discordUseDetails.value = value
        settings.putBoolean("discord_use_details", value)
    }

    private val _discordAdvancedMode = MutableStateFlow(settings.getBoolean("discord_advanced_mode", false))
    val discordAdvancedMode: StateFlow<Boolean> = _discordAdvancedMode.asStateFlow()
    fun setDiscordAdvancedMode(value: Boolean) {
        _discordAdvancedMode.value = value
        settings.putBoolean("discord_advanced_mode", value)
    }

    private val _discordButton1Text = MutableStateFlow(settings.getString("discord_button_1_text", ""))
    val discordButton1Text: StateFlow<String> = _discordButton1Text.asStateFlow()
    fun setDiscordButton1Text(value: String) {
        _discordButton1Text.value = value
        settings.putString("discord_button_1_text", value)
    }

    private val _discordButton1Visible = MutableStateFlow(settings.getBoolean("discord_button_1_visible", true))
    val discordButton1Visible: StateFlow<Boolean> = _discordButton1Visible.asStateFlow()
    fun setDiscordButton1Visible(value: Boolean) {
        _discordButton1Visible.value = value
        settings.putBoolean("discord_button_1_visible", value)
    }

    private val _discordButton2Text = MutableStateFlow(settings.getString("discord_button_2_text", ""))
    val discordButton2Text: StateFlow<String> = _discordButton2Text.asStateFlow()
    fun setDiscordButton2Text(value: String) {
        _discordButton2Text.value = value
        settings.putString("discord_button_2_text", value)
    }

    private val _discordButton2Visible = MutableStateFlow(settings.getBoolean("discord_button_2_visible", true))
    val discordButton2Visible: StateFlow<Boolean> = _discordButton2Visible.asStateFlow()
    fun setDiscordButton2Visible(value: Boolean) {
        _discordButton2Visible.value = value
        settings.putBoolean("discord_button_2_visible", value)
    }

    private val _discordInfoDismissed = MutableStateFlow(settings.getBoolean("discord_info_dismissed", false))
    val discordInfoDismissed: StateFlow<Boolean> = _discordInfoDismissed.asStateFlow()
    fun setDiscordInfoDismissed(value: Boolean) {
        _discordInfoDismissed.value = value
        settings.putBoolean("discord_info_dismissed", value)
    }

    private val _discordName = MutableStateFlow(settings.getString("discord_name", ""))
    val discordName: StateFlow<String> = _discordName.asStateFlow()
    fun setDiscordName(value: String) {
        _discordName.value = value.trim()
        settings.putString("discord_name", _discordName.value)
    }

    private val _discordAvatar = MutableStateFlow(settings.getString("discord_avatar", ""))
    val discordAvatar: StateFlow<String> = _discordAvatar.asStateFlow()
    fun setDiscordAvatar(value: String) {
        _discordAvatar.value = value.trim()
        settings.putString("discord_avatar", _discordAvatar.value)
    }

    private val _scrobbleMinDuration = MutableStateFlow(settings.getInt("scrobble_min_duration", 30))
    val scrobbleMinDuration: StateFlow<Int> = _scrobbleMinDuration.asStateFlow()
    fun setScrobbleMinDuration(value: Int) {
        _scrobbleMinDuration.value = value.coerceIn(10, 120)
        settings.putInt("scrobble_min_duration", _scrobbleMinDuration.value)
    }

    private val _scrobbleDelayPercent = MutableStateFlow(settings.getFloat("scrobble_delay_percent", 0.5f))
    val scrobbleDelayPercent: StateFlow<Float> = _scrobbleDelayPercent.asStateFlow()
    fun setScrobbleDelayPercent(value: Float) {
        _scrobbleDelayPercent.value = value.coerceIn(0.25f, 0.9f)
        settings.putFloat("scrobble_delay_percent", _scrobbleDelayPercent.value)
    }

    private val _scrobbleDelaySeconds = MutableStateFlow(settings.getInt("scrobble_delay_seconds", 180))
    val scrobbleDelaySeconds: StateFlow<Int> = _scrobbleDelaySeconds.asStateFlow()
    fun setScrobbleDelaySeconds(value: Int) {
        _scrobbleDelaySeconds.value = value.coerceIn(30, 480)
        settings.putInt("scrobble_delay_seconds", _scrobbleDelaySeconds.value)
    }

    private val _pinnedPlaylists = MutableStateFlow(settings.getString("pinned_playlists", ""))
    val pinnedPlaylists: StateFlow<String> = _pinnedPlaylists.asStateFlow()
    fun setPinnedPlaylists(value: String) {
        _pinnedPlaylists.value = value
        settings.putString("pinned_playlists", value)
    }

    /**
     * Pins or unpins [browseId], returning whether it is pinned afterwards.
     * Pinning past [MAX_PINNED_PLAYLISTS] is refused rather than evicting.
     */
    fun togglePinnedPlaylist(browseId: String): Boolean {
        val ids = _pinnedPlaylists.value.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        val updated = when {
            browseId in ids -> ids - browseId
            ids.size >= MAX_PINNED_PLAYLISTS -> return false
            else -> ids + browseId
        }
        setPinnedPlaylists(updated.joinToString(","))
        return browseId in updated
    }

    private val _spotifySpdc = MutableStateFlow(settings.getSecret("spotify_spdc_token").orEmpty())
    val spotifySpdc: StateFlow<String> = _spotifySpdc.asStateFlow()
    fun setSpotifySpdc(value: String) {
        _spotifySpdc.value = value.trim()
        settings.putSecret("spotify_spdc_token", _spotifySpdc.value.ifEmpty { null })
    }

    private val _jiosaavnEnabled = MutableStateFlow(settings.getBoolean("jiosaavn_enabled", true))
    val jiosaavnEnabled: StateFlow<Boolean> = _jiosaavnEnabled.asStateFlow()
    fun setJiosaavnEnabled(value: Boolean) {
        _jiosaavnEnabled.value = value
        settings.putBoolean("jiosaavn_enabled", value)
    }

    private val _stopWhenBackgrounded = MutableStateFlow(settings.getBoolean("stop_when_backgrounded", false))
    val stopWhenBackgrounded: StateFlow<Boolean> = _stopWhenBackgrounded.asStateFlow()
    fun setStopWhenBackgrounded(value: Boolean) {
        _stopWhenBackgrounded.value = value
        settings.putBoolean("stop_when_backgrounded", value)
    }

    private val _prioritizeSyllableSync = MutableStateFlow(settings.getBoolean("prioritize_syllable_sync", true))
    val prioritizeSyllableSync: StateFlow<Boolean> = _prioritizeSyllableSync.asStateFlow()
    fun setPrioritizeSyllableSync(value: Boolean) {
        _prioritizeSyllableSync.value = value
        settings.putBoolean("prioritize_syllable_sync", value)
    }

    private val _replayGenres = MutableStateFlow(settings.getBoolean("replay_genres", true))
    val replayGenres: StateFlow<Boolean> = _replayGenres.asStateFlow()
    fun setReplayGenres(value: Boolean) {
        _replayGenres.value = value
        settings.putBoolean("replay_genres", value)
    }

    // ---- Audio output & performance (upstream parity) -----------------------
    //
    // The hardware-facing half of these (PCM word length, USB route, loudness
    // stage) is owned by the platform engine, not here: this tier holds the
    // choice, the engine applies what it can, and the Audio Pipeline readout
    // names what is actually in effect. Persisting the key with upstream's name
    // is what keeps a settings dump readable across ports.

    /**
     * Requested PCM word length at the output boundary: PCM_16 or FLOAT_32,
     * upstream's two rungs (Media3's sink has no packed-24 path, and neither
     * does this port's engine). A stored PCM_24 predates the rung's removal
     * and migrates to the lossless path; anything else unknown falls back to
     * PCM_16.
     */
    private val _outputPcmMode = MutableStateFlow(
        when (settings.getString("output_pcm_mode", "PCM_16")) {
            "FLOAT_32", "PCM_24" -> "FLOAT_32"
            else -> "PCM_16"
        },
    )
    val outputPcmMode: StateFlow<String> = _outputPcmMode.asStateFlow()
    fun setOutputPcmMode(value: String) {
        val mode = if (value == "FLOAT_32") value else "PCM_16"
        _outputPcmMode.value = mode
        settings.putString("output_pcm_mode", mode)
    }

    /** Prefer an attached USB audio output over the system's normal route. */
    private val _preferUsbDac = MutableStateFlow(settings.getBoolean("prefer_usb_dac", false))
    val preferUsbDac: StateFlow<Boolean> = _preferUsbDac.asStateFlow()
    fun setPreferUsbDac(value: Boolean) {
        _preferUsbDac.value = value
        settings.putBoolean("prefer_usb_dac", value)
    }

    /**
     * Attenuate tracks whose source reports a loudness above target. The Apple
     * mixer avoids positive gain because stream metadata does not include a
     * true-peak ceiling; boosting a full-scale master can clip.
     */
    private val _soundMode = MutableStateFlow(SoundMode.entries.firstOrNull { it.name == settings.getString("sound_mode", "TRANSPARENT") } ?: SoundMode.TRANSPARENT)
    val soundMode: StateFlow<SoundMode> = _soundMode.asStateFlow()
    fun setSoundMode(value: SoundMode) { _soundMode.value=value;settings.putString("sound_mode",value.name) }
    private val _clarityTuning = MutableStateFlow(ClarityTuning(
        preset=ClarityPreset.entries.firstOrNull { it.name == settings.getString("clarity_preset", "REFERENCE") } ?: ClarityPreset.REFERENCE,
        wet=settings.getFloat("clarity_wet",1f).takeIf { it.isFinite() }?.coerceIn(0f,1f) ?: 1f,
        trimsDb=settings.getString("clarity_trims", "").split(",").mapNotNull { it.toFloatOrNull()?.takeIf { v -> v.isFinite() }?.coerceIn(-12f,12f) }.takeIf { it.size==8 } ?: List(8) { 0f }
    ))
    val clarityTuning: StateFlow<ClarityTuning> = _clarityTuning.asStateFlow()
    fun setClarityTuning(value: ClarityTuning) {
        val clean=value.copy(wet=value.wet.takeIf { it.isFinite() }?.coerceIn(0f,1f) ?: 1f,trimsDb=List(8) { i -> value.trimsDb.getOrNull(i)?.takeIf { it.isFinite() }?.coerceIn(-12f,12f) ?: 0f })
        _clarityTuning.value=clean;settings.putString("clarity_preset",clean.preset.name);settings.putFloat("clarity_wet",clean.wet);settings.putString("clarity_trims",clean.trimsDb.joinToString(","))
    }
    // Preserve explicit Off; otherwise retain the upstream and legacy Track default.
    private val _loudnessMode = MutableStateFlow(LoudnessMode.entries.firstOrNull { it.name == settings.getString("loudness_mode", if(settings.getBoolean("loudness_normalization",true)) "TRACK" else "OFF") } ?: LoudnessMode.OFF)
    val loudnessMode: StateFlow<LoudnessMode> = _loudnessMode.asStateFlow()
    fun setLoudnessMode(value: LoudnessMode) { _loudnessMode.value=value;settings.putString("loudness_mode",value.name);setLoudnessNormalization(value!=LoudnessMode.OFF) }

    private val _loudnessNormalization = MutableStateFlow(_loudnessMode.value != LoudnessMode.OFF)
    val loudnessNormalization: StateFlow<Boolean> = _loudnessNormalization.asStateFlow()
    fun setLoudnessNormalization(value: Boolean) {
        _loudnessNormalization.value = value
        _loudnessMode.value=if(!value) LoudnessMode.OFF else if(_loudnessMode.value==LoudnessMode.OFF) LoudnessMode.TRACK else _loudnessMode.value
        settings.putString("loudness_mode",_loudnessMode.value.name)
        settings.putBoolean("loudness_normalization", value)
    }

    /** Allow normalization to be skipped on a phone's built-in speaker. */
    private val _loudnessOffOnSpeaker = MutableStateFlow(settings.getBoolean("loudness_off_on_speaker", true))
    val loudnessOffOnSpeaker: StateFlow<Boolean> = _loudnessOffOnSpeaker.asStateFlow()
    fun setLoudnessOffOnSpeaker(value: Boolean) {
        _loudnessOffOnSpeaker.value = value
        settings.putBoolean("loudness_off_on_speaker", value)
    }

    /** Duration tolerance for preferring a same-recording source match. */
    private val _upgradeLengthSlackSeconds = MutableStateFlow(
        settings.getInt(KEY_UPGRADE_LENGTH_SLACK_SECONDS, DEFAULT_UPGRADE_LENGTH_SLACK_SECONDS)
            .coerceIn(MIN_UPGRADE_LENGTH_SLACK_SECONDS, MAX_UPGRADE_LENGTH_SLACK_SECONDS),
    )
    val upgradeLengthSlackSeconds: StateFlow<Int> = _upgradeLengthSlackSeconds.asStateFlow()
    fun setUpgradeLengthSlackSeconds(value: Int) {
        val bounded = value.coerceIn(MIN_UPGRADE_LENGTH_SLACK_SECONDS, MAX_UPGRADE_LENGTH_SLACK_SECONDS)
        _upgradeLengthSlackSeconds.value = bounded
        settings.putInt(KEY_UPGRADE_LENGTH_SLACK_SECONDS, bounded)
    }

    /** Whether the expanded player's system status bar is hidden. */
    private val _hideStatusBarInPlayer = MutableStateFlow(settings.getBoolean("hide_status_bar_in_player", false))
    val hideStatusBarInPlayer: StateFlow<Boolean> = _hideStatusBarInPlayer.asStateFlow()
    fun setHideStatusBarInPlayer(value: Boolean) {
        _hideStatusBarInPlayer.value = value
        settings.putBoolean("hide_status_bar_in_player", value)
    }

    /** Include tracks before the current cursor in the player queue. */
    private val _showQueueHistory = MutableStateFlow(settings.getBoolean("show_queue_history", false))
    val showQueueHistory: StateFlow<Boolean> = _showQueueHistory.asStateFlow()
    fun setShowQueueHistory(value: Boolean) {
        _showQueueHistory.value = value
        settings.putBoolean("show_queue_history", value)
    }

    /** Pause playback when the Mac's main window is closed. */
    private val _stopMusicOnClose = MutableStateFlow(settings.getBoolean("stop_music_on_close", false))
    val stopMusicOnClose: StateFlow<Boolean> = _stopMusicOnClose.asStateFlow()
    fun setStopMusicOnClose(value: Boolean) {
        _stopMusicOnClose.value = value
        settings.putBoolean("stop_music_on_close", value)
    }

    /** Show artist signatures sourced from Wikimedia on artist pages. */
    private val _artistSignaturesEnabled = MutableStateFlow(settings.getBoolean("artist_signatures_enabled", true))
    val artistSignaturesEnabled: StateFlow<Boolean> = _artistSignaturesEnabled.asStateFlow()
    fun setArtistSignaturesEnabled(value: Boolean) {
        _artistSignaturesEnabled.value = value
        settings.putBoolean("artist_signatures_enabled", value)
    }

    /** Optional Wikimedia URL override; empty uses the app's default endpoint. */
    private val _artistSignaturesWikimediaUrl = MutableStateFlow(settings.getString("artist_signatures_wikimedia_url", ""))
    val artistSignaturesWikimediaUrl: StateFlow<String> = _artistSignaturesWikimediaUrl.asStateFlow()
    fun setArtistSignaturesWikimediaUrl(value: String) {
        val clean = value.trim()
        _artistSignaturesWikimediaUrl.value = clean
        settings.putString("artist_signatures_wikimedia_url", clean)
    }

    const val DEFAULT_UPGRADE_LENGTH_SLACK_SECONDS = 3
    const val MIN_UPGRADE_LENGTH_SLACK_SECONDS = 0
    const val MAX_UPGRADE_LENGTH_SLACK_SECONDS = 10

    /** CPU budget for Automix's background analysis, not its audible mix. */
    private val _automixPerformanceMode = MutableStateFlow(
        settings.getString("automix_performance", "BALANCED").takeIf {
            it == "EFFICIENT" || it == "BALANCED" || it == "PERFORMANCE"
        } ?: "BALANCED",
    )
    val automixPerformanceMode: StateFlow<String> = _automixPerformanceMode.asStateFlow()
    fun setAutomixPerformanceMode(value: String) {
        val mode = if (value == "EFFICIENT" || value == "PERFORMANCE") value else "BALANCED"
        _automixPerformanceMode.value = mode
        settings.putString("automix_performance", mode)
    }

    /** Inference threads for [automixPerformanceMode]: 1, 2 or 4. */
    fun automixInferenceThreads(): Int = when (_automixPerformanceMode.value) {
        "EFFICIENT" -> 1
        "PERFORMANCE" -> 4
        else -> 2
    }

    /** Requests a sustained high-refresh UI. Off keeps the system's own policy. */
    private val _highPerformanceMode = MutableStateFlow(settings.getBoolean("high_performance_mode", false))
    val highPerformanceMode: StateFlow<Boolean> = _highPerformanceMode.asStateFlow()
    fun setHighPerformanceMode(value: Boolean) {
        _highPerformanceMode.value = value
        settings.putBoolean("high_performance_mode", value)
    }

    /** Preferred UI refresh rate in Hz while [highPerformanceMode] is on. */
    private val _performanceRefreshRate = MutableStateFlow(
        settings.getInt("performance_refresh_rate", 60).coerceIn(30, 240),
    )
    val performanceRefreshRate: StateFlow<Int> = _performanceRefreshRate.asStateFlow()
    fun setPerformanceRefreshRate(value: Int) {
        _performanceRefreshRate.value = value.coerceIn(30, 240)
        settings.putInt("performance_refresh_rate", _performanceRefreshRate.value)
    }

    /**
     * Keep downloads in Music/BitChord where other music apps can see them.
     * Off keeps downloads in this app's private storage.
     */
    private val _exportDownloads = MutableStateFlow(settings.getBoolean("export_downloads", false))
    val exportDownloads: StateFlow<Boolean> = _exportDownloads.asStateFlow()
    fun setExportDownloads(value: Boolean) {
        _exportDownloads.value = value
        settings.putBoolean("export_downloads", value)
    }

    /** Hides the "Playing from" / "Played by" caption on the main player. */
    private val _hideSongStatus = MutableStateFlow(settings.getBoolean("hide_song_status", false))
    val hideSongStatus: StateFlow<Boolean> = _hideSongStatus.asStateFlow()
    fun setHideSongStatus(value: Boolean) {
        _hideSongStatus.value = value
        settings.putBoolean("hide_song_status", value)
    }

    /**
     * Prefer the catalogue audio release when the selected result is a music
     * video. The video itself still plays first so its metadata appears
     * immediately while the catalogue match is resolved.
     */
    private val _preferMusicOnly = MutableStateFlow(settings.getBoolean("prefer_music_only", false))
    val preferMusicOnly: StateFlow<Boolean> = _preferMusicOnly.asStateFlow()
    fun setPreferMusicOnly(value: Boolean) {
        _preferMusicOnly.value = value
        settings.putBoolean("prefer_music_only", value)
    }

    /** Aligns the matching playback moment when switching between versions. */
    private val _smartVersionAlignment = MutableStateFlow(settings.getBoolean("smart_version_alignment", true))
    val smartVersionAlignment: StateFlow<Boolean> = _smartVersionAlignment.asStateFlow()
    fun setSmartVersionAlignment(value: Boolean) {
        _smartVersionAlignment.value = value
        settings.putBoolean("smart_version_alignment", value)
    }

    /** Hides short clips, recorder output and non-music formats from Local Music. */
    private val _filterNonMusicAudio = MutableStateFlow(settings.getBoolean("filter_non_music_audio", true))
    val filterNonMusicAudio: StateFlow<Boolean> = _filterNonMusicAudio.asStateFlow()
    fun setFilterNonMusicAudio(value: Boolean) {
        _filterNonMusicAudio.value = value
        settings.putBoolean("filter_non_music_audio", value)
    }

    /** Puts the legacy single-wash backdrop back on the player. */
    private val _legacyMeshGradient = MutableStateFlow(settings.getBoolean("legacy_mesh_gradient", false))
    val legacyMeshGradient: StateFlow<Boolean> = _legacyMeshGradient.asStateFlow()
    fun setLegacyMeshGradient(value: Boolean) {
        _legacyMeshGradient.value = value
        settings.putBoolean("legacy_mesh_gradient", value)
    }

    /**
     * Which artist a scrobble credits: the full track credit ("track") or the
     * lead name alone ("album"). Mirrors upstream's per-service
     * `primaryArtistOnly` flags as one choice, since both services receive the
     * same payload from the same call site.
     */
    private val _scrobblePrimaryArtist = MutableStateFlow(
        settings.getString("scrobble_primary_artist", "track").takeIf {
            it == "album"
        } ?: "track",
    )
    val scrobblePrimaryArtist: StateFlow<String> = _scrobblePrimaryArtist.asStateFlow()
    fun setScrobblePrimaryArtist(value: String) {
        val mode = if (value == "album") "album" else "track"
        _scrobblePrimaryArtist.value = mode
        settings.putString("scrobble_primary_artist", mode)
    }

    /** The lead name of a multi-artist credit — upstream `PrimaryArtist`. */
    fun primaryArtist(credit: String): String =
        credit.split(Regex("""\s*,\s*|\s+&\s+|\s+＆\s+"""), limit = 2).first().trim().ifBlank { credit }

    /**
     * The account this device is signed in as, as far as Listen Together cares.
     *
     * Cached here rather than read from the network on demand because the signed-in
     * name is wanted the moment somebody taps Join, and a party is a LAN-scale thing
     * where a round trip to work out what to call somebody is a visible stall. It is
     * also the only account detail the feature has any use for.
     *
     * A cache rather than a source of truth: null means "not known", which includes
     * signed out. The identity it feeds falls back to a local name when it is null, so
     * nothing here is load-bearing.
     */
    private val _partyAccount = MutableStateFlow<PartyAccount?>(null)
    val partyAccount: StateFlow<PartyAccount?> = _partyAccount.asStateFlow()
    fun setPartyAccount(value: PartyAccount?) {
        _partyAccount.value = value
    }

    /**
     * The party server this device talks to, empty when the listener has not named
     * one.
     *
     * Empty is the shipped default and the build's own default is empty too, on
     * purpose: a party server is a deployment somebody has to run, so the app asks
     * the listener for theirs rather than coupling every install to one address's
     * uptime.
     */
    private val _listenTogetherServer = MutableStateFlow(settings.getString(KEY_LISTEN_SERVER, ""))
    val listenTogetherServer: StateFlow<String> = _listenTogetherServer.asStateFlow()
    fun setListenTogetherServer(value: String) {
        val trimmed = value.trim()
        _listenTogetherServer.value = trimmed
        settings.putString(KEY_LISTEN_SERVER, trimmed)
    }

    /**
     * The name this device joins a party under, empty when the listener has not
     * chosen one.
     *
     * Empty is meaningful and not the same as a default: the name actually shown is
     * the signed-in account's, and this is an override of it.
     */
    private val _listenTogetherNickname = MutableStateFlow(settings.getString(KEY_LISTEN_NICKNAME, ""))
    val listenTogetherNickname: StateFlow<String> = _listenTogetherNickname.asStateFlow()
    fun setListenTogetherNickname(value: String) {
        val trimmed = value.trim().take(MAX_NICKNAME_LENGTH)
        _listenTogetherNickname.value = trimmed
        settings.putString(KEY_LISTEN_NICKNAME, trimmed)
    }

    /**
     * The remote library this device reads over WebDAV.
     *
     * The address and the username are configuration and live in plain preferences,
     * as upstream has them; the **password** is a credential and goes through
     * [PlatformSettings.getSecret], which is the Keychain on Apple. That split is
     * upstream's and it is the reason: upstream keeps the password in its encrypted
     * `AuthStore` and mirrors it out into the flow, so it never appears in the
     * preference file at all — and the file is what `exportPrefsJson` reads.
     *
     * [webDavUrl] is stored normalized ([WebDavConfig.normalizeUrl]) rather than as
     * typed, so the address a listing dials is the address the settings screen shows.
     * A trailing slash trimmed at use and not at save is how a share ends up with
     * `//` between two of its own path segments, which some servers treat as a
     * different folder.
     */
    private val _webDavUrl = MutableStateFlow(
        WebDavConfig.normalizeUrl(settings.getString(KEY_WEBDAV_URL, "")),
    )
    val webDavUrl: StateFlow<String> = _webDavUrl.asStateFlow()

    private val _webDavUsername = MutableStateFlow(settings.getString(KEY_WEBDAV_USERNAME, ""))
    val webDavUsername: StateFlow<String> = _webDavUsername.asStateFlow()

    private val _webDavPassword = MutableStateFlow(settings.getSecret(KEY_WEBDAV_PASSWORD).orEmpty())
    val webDavPassword: StateFlow<String> = _webDavPassword.asStateFlow()

    fun setWebDavUrl(value: String) {
        val normalized = WebDavConfig.normalizeUrl(value)
        _webDavUrl.value = normalized
        settings.putString(KEY_WEBDAV_URL, normalized)
    }

    fun setWebDavUsername(value: String) {
        val trimmed = value.trim()
        _webDavUsername.value = trimmed
        settings.putString(KEY_WEBDAV_USERNAME, trimmed)
    }

    /** Writes through to the Keychain; pass "" to forget. */
    fun setWebDavPassword(value: String) {
        _webDavPassword.value = value
        settings.putSecret(KEY_WEBDAV_PASSWORD, value.ifEmpty { null })
    }

    /**
     * Whether there is anything to dial.
     *
     * The library reads as empty when this is false rather than refusing to open, so
     * the check belongs here and not in every caller.
     */
    fun isWebDavConfigured(): Boolean = WebDavConfig.isConfigured(_webDavUrl.value)

    /** Forgets the share and its credential together, so neither is left half-set. */
    fun clearWebDav() {
        setWebDavUrl("")
        setWebDavUsername("")
        setWebDavPassword("")
    }

    /**
     * Keys that must never leave the device in a backup.
     *
     * `listen_together_server` and `listen_together_nickname` are absent, and that is
     * a decision rather than an oversight: the first is a LAN address that means
     * nothing on another machine, and the second is personal. Neither is in the
     * exported key list below for either reason — nor is the per-install id, which
     * would make two machines claim one identity.
     *
     * `webdav_password` is here for the reason every other entry is: it is a
     * credential, and an import must not be able to write one. Upstream does not need
     * the entry for its own password — the password never enters its preference file,
     * so there is nothing to filter — but the entry is the portable statement of the
     * same rule, and it is what stops an import from putting one there.
     */
    private val SECRET_KEYS = setOf(
        "discord_token", "lastfm_session", "lastfm_secret", "lastfm_api_key",
        "listenbrainz_token", "spotify_spdc_token", "paxsenix_api_key",
        KEY_WEBDAV_PASSWORD,
    )

    fun exportPrefsJson(): String {
        val keys = listOf(
            "crossfade_seconds", "smart_fade_enabled", "spatial_audio", "autoplay",
            "skip_silence", "trim_edge_silence", "skip_non_music", "playback_speed", "audio_quality_wifi", "audio_quality_cellular",
            "download_quality", "wifi_only_downloads", "show_nerd_stats", "animated_canvas",
            "canvas_over_cellular", "prioritize_spotify_canvas", "theme_mode", "reduce_dynamic_blur", "reduce_animation",
            "full_bleed_artwork", "synced_lyrics", "dolby_atmos", "lyrics_blur", "translation_language", "convert_video_to_audio", "swipe_to_play_next",
            "dont_repeat_suggestions", "hide_volume_bar", "lyrics_sources", "lyrics_source_order",
            KEY_UPGRADE_LENGTH_SLACK_SECONDS, "loudness_off_on_speaker", "hide_status_bar_in_player",
            "show_queue_history", "stop_music_on_close", "artist_signatures_enabled", "artist_signatures_wikimedia_url",
            "audio_cache_limit_bytes",
            "eq_gains", "pinned_playlists", "jiosaavn_enabled", "stop_when_backgrounded",
            "prioritize_syllable_sync", "replay_genres", "scrobble_min_duration", "scrobble_delay_percent",
            "sound_mode", "clarity_preset", "clarity_wet", "clarity_trims", "loudness_mode",
            "scrobble_delay_seconds", "output_pcm_mode", "prefer_usb_dac", "loudness_normalization",
            "automix_performance", "high_performance_mode", "performance_refresh_rate",
            "export_downloads", "hide_song_status", "prefer_music_only", "smart_version_alignment",
            "filter_non_music_audio", "legacy_mesh_gradient", "scrobble_primary_artist",
            "discord_rpc_enabled", "discord_status",
            "discord_activity_type", "discord_activity_name", "discord_swap_title",
            "discord_use_details", "discord_advanced_mode", "discord_button_1_text",
            "discord_button_1_visible", "discord_button_2_text", "discord_button_2_visible",
            "discord_info_dismissed", "discord_name", "discord_avatar",
            // The share's address and account, and not its password: moving a
            // configuration to a new machine should not mean re-typing where the
            // library is, and should certainly not mean handing over a credential.
            KEY_WEBDAV_URL, KEY_WEBDAV_USERNAME,
        )
        val parts = keys.map { key ->
            val value = when (key) {
                "lyrics_blur", "dolby_atmos" -> settings.getBoolean(key, true).toString()
                "crossfade_seconds", "scrobble_min_duration", "scrobble_delay_seconds",
                "performance_refresh_rate" ->
                    settings.getInt(key, 0).toString()
                KEY_UPGRADE_LENGTH_SLACK_SECONDS ->
                    settings.getInt(key, DEFAULT_UPGRADE_LENGTH_SLACK_SECONDS).toString()
                "audio_cache_limit_bytes" -> settings.getLong(key, DEFAULT_CACHE_LIMIT_BYTES).toString()
                "clarity_wet", "scrobble_delay_percent", "playback_speed" -> settings.getFloat(key, 0f).toString()
                "smart_fade_enabled", "spatial_audio", "autoplay", "skip_silence", "trim_edge_silence", "skip_non_music",
                "wifi_only_downloads", "show_nerd_stats", "animated_canvas", "canvas_over_cellular",
                "prioritize_spotify_canvas",
                "reduce_dynamic_blur", "reduce_animation", "full_bleed_artwork", "synced_lyrics",
                "convert_video_to_audio", "swipe_to_play_next", "dont_repeat_suggestions",
                "hide_volume_bar", "jiosaavn_enabled", "stop_when_backgrounded",
                "prioritize_syllable_sync", "replay_genres", "discord_rpc_enabled", "discord_swap_title",
                "prefer_usb_dac", "loudness_normalization", "high_performance_mode",
                "loudness_off_on_speaker", "hide_status_bar_in_player", "show_queue_history", "stop_music_on_close", "artist_signatures_enabled",
                "export_downloads", "hide_song_status", "prefer_music_only", "smart_version_alignment",
                "filter_non_music_audio", "legacy_mesh_gradient",
                "discord_use_details", "discord_advanced_mode", "discord_info_dismissed",
                "discord_button_1_visible", "discord_button_2_visible",
                -> when (key) {
                    "discord_button_1_visible", "discord_button_2_visible" ->
                        settings.getBoolean(key, true).toString()
                    "loudness_off_on_speaker" -> settings.getBoolean(key, true).toString()
                    "artist_signatures_enabled" -> settings.getBoolean(key, true).toString()
                    else -> settings.getBoolean(key, false).toString()
                }
                else -> settings.getString(key, "")
            }
            "\"$key\":${jsonString(value)}"
        }
        return "{${parts.joinToString(",")}}"
    }

    fun importPrefsJson(raw: String) {
        val obj = Json.parseToJsonElement(raw) as? JsonObject
            ?: throw IllegalArgumentException("Settings backup must be a JSON object")
        obj.forEach { (key, element) ->
            if (key in SECRET_KEYS || element is JsonNull) return@forEach
            val value = (element as? JsonPrimitive)?.content ?: return@forEach
            when (key) {
                "crossfade_seconds" -> setCrossfadeSeconds(value.toIntOrNull() ?: 0)
                "smart_fade_enabled" -> setSmartFadeEnabled(value.toBoolean())
                "spatial_audio" -> setSpatialAudio(value.toBoolean())
                "autoplay" -> setAutoplay(value.toBoolean())
                "skip_silence" -> setSkipSilence(value.toBoolean())
                "playback_speed" -> setPlaybackSpeed(value.toFloatOrNull() ?: 1f)
                "audio_quality_wifi" -> setAudioQualityWifi(value)
                "audio_quality_cellular" -> setAudioQualityCellular(value)
                "download_quality" -> setDownloadQuality(value)
                "wifi_only_downloads" -> setWifiOnlyDownloads(value.toBoolean())
                "show_nerd_stats" -> setShowNerdStats(value.toBoolean())
                "animated_canvas" -> setAnimatedCanvas(value.toBoolean())
                "canvas_over_cellular" -> setCanvasOverCellular(value.toBoolean())
                "prioritize_spotify_canvas" -> setPrioritizeSpotifyCanvas(value.toBoolean())
                "theme_mode" -> setThemeMode(value)
                "reduce_dynamic_blur" -> setReduceDynamicBlur(value.toBoolean())
                "reduce_animation" -> setReduceAnimation(value.toBoolean())
                "full_bleed_artwork" -> setFullBleedArtwork(value.toBoolean())
                "synced_lyrics" -> setSyncedLyrics(value.toBoolean())
                "dolby_atmos" -> setDolbyAtmos(value.toBoolean())
                "lyrics_blur" -> setLyricsBlur(value.toBoolean())
                "translation_language" -> setTranslationLanguage(value)
                "convert_video_to_audio" -> setConvertVideoToAudio(value.toBoolean())
                "swipe_to_play_next" -> setSwipeToPlayNext(value.toBoolean())
                "dont_repeat_suggestions" -> setDontRepeatSuggestions(value.toBoolean())
                "hide_volume_bar" -> setHideVolumeBar(value.toBoolean())
                "lyrics_sources" -> setLyricsSources(value)
                "lyrics_source_order" -> setLyricsSourceOrder(value)
                "audio_cache_limit_bytes" -> setAudioCacheLimitBytes(value.toLongOrNull() ?: DEFAULT_CACHE_LIMIT_BYTES)
                "eq_gains" -> setEqGains(value)
                "pinned_playlists" -> setPinnedPlaylists(value)
                "jiosaavn_enabled" -> setJiosaavnEnabled(value.toBoolean())
                "stop_when_backgrounded" -> setStopWhenBackgrounded(value.toBoolean())
                "prioritize_syllable_sync" -> setPrioritizeSyllableSync(value.toBoolean())
                "replay_genres" -> setReplayGenres(value.toBoolean())
                "scrobble_min_duration" -> setScrobbleMinDuration(value.toIntOrNull() ?: 30)
                "scrobble_delay_percent" -> setScrobbleDelayPercent(value.toFloatOrNull() ?: 0.5f)
                "scrobble_delay_seconds" -> setScrobbleDelaySeconds(value.toIntOrNull() ?: 180)
                "output_pcm_mode" -> setOutputPcmMode(value)
                "prefer_usb_dac" -> setPreferUsbDac(value.toBoolean())
                "sound_mode" -> setSoundMode(SoundMode.entries.firstOrNull { it.name==value } ?: SoundMode.TRANSPARENT)
                "loudness_mode" -> setLoudnessMode(LoudnessMode.entries.firstOrNull { it.name==value } ?: LoudnessMode.OFF)
                "clarity_preset" -> setClarityTuning(_clarityTuning.value.copy(preset=ClarityPreset.entries.firstOrNull { it.name==value } ?: ClarityPreset.REFERENCE))
                "clarity_wet" -> setClarityTuning(_clarityTuning.value.copy(wet=value.toFloatOrNull() ?: 1f))
                "clarity_trims" -> setClarityTuning(_clarityTuning.value.copy(trimsDb=value.split(",").map { it.toFloatOrNull() ?: 0f }))
                "loudness_normalization" -> setLoudnessNormalization(value.toBoolean())
                "loudness_off_on_speaker" -> setLoudnessOffOnSpeaker(value.toBoolean())
                KEY_UPGRADE_LENGTH_SLACK_SECONDS -> setUpgradeLengthSlackSeconds(value.toIntOrNull() ?: DEFAULT_UPGRADE_LENGTH_SLACK_SECONDS)
                "hide_status_bar_in_player" -> setHideStatusBarInPlayer(value.toBoolean())
                "show_queue_history" -> setShowQueueHistory(value.toBoolean())
                "stop_music_on_close" -> setStopMusicOnClose(value.toBoolean())
                "artist_signatures_enabled" -> setArtistSignaturesEnabled(value.toBoolean())
                "artist_signatures_wikimedia_url" -> setArtistSignaturesWikimediaUrl(value)
                "automix_performance" -> setAutomixPerformanceMode(value)
                "high_performance_mode" -> setHighPerformanceMode(value.toBoolean())
                "performance_refresh_rate" -> setPerformanceRefreshRate(value.toIntOrNull() ?: 60)
                "export_downloads" -> setExportDownloads(value.toBoolean())
                "hide_song_status" -> setHideSongStatus(value.toBoolean())
                "prefer_music_only" -> setPreferMusicOnly(value.toBoolean())
                "smart_version_alignment" -> setSmartVersionAlignment(value.toBoolean())
                "filter_non_music_audio" -> setFilterNonMusicAudio(value.toBoolean())
                "legacy_mesh_gradient" -> setLegacyMeshGradient(value.toBoolean())
                "scrobble_primary_artist" -> setScrobblePrimaryArtist(value)
                "discord_rpc_enabled" -> setDiscordRpcEnabled(value.toBoolean())
                "discord_status" -> setDiscordStatus(value)
                "discord_activity_type" -> setDiscordActivityType(value)
                "discord_activity_name" -> setDiscordActivityName(value)
                "discord_swap_title" -> setDiscordSwapTitle(value.toBoolean())
                "discord_use_details" -> setDiscordUseDetails(value.toBoolean())
                "discord_advanced_mode" -> setDiscordAdvancedMode(value.toBoolean())
                "discord_button_1_text" -> setDiscordButton1Text(value)
                "discord_button_1_visible" -> setDiscordButton1Visible(value.toBoolean())
                "discord_button_2_text" -> setDiscordButton2Text(value)
                "discord_button_2_visible" -> setDiscordButton2Visible(value.toBoolean())
                "discord_info_dismissed" -> setDiscordInfoDismissed(value.toBoolean())
                "discord_name" -> setDiscordName(value)
                "discord_avatar" -> setDiscordAvatar(value)
                KEY_WEBDAV_URL -> setWebDavUrl(value)
                KEY_WEBDAV_USERNAME -> setWebDavUsername(value)
                // `KEY_WEBDAV_PASSWORD` is absent on purpose: [SECRET_KEYS] has already
                // refused the chunk, and a `when` that listed it would be a lie about
                // that. The password on a restored machine has to be typed again.
            }
        }
    }

    private fun jsonString(s: String): String = JsonPrimitive(s).toString()

    fun effectiveAudioQuality(metered: Boolean): AudioQuality =
        if (metered) audioQualityCellular.value else audioQualityWifi.value

    /**
     * Whether the connection in hand is metered, or null when that is not known.
     *
     * A `StateFlow` rather than a parameter because it changes under the app's
     * feet — someone walks out of Wi-Fi range mid-album — and every source walk
     * has to answer against the connection as it is *now*, not as it was when the
     * queue was built.
     *
     * Null is meaningfully different from `false`: "not known yet" must not be
     * read as unmetered, or a phone that has not finished its first path
     * evaluation would start streaming lossless over cellular. Until it is known,
     * callers fall back to the Wi-Fi setting, which is the conservative reading
     * for the common case of an app that starts on Wi-Fi.
     */
    private val _meteredConnection = MutableStateFlow<Boolean?>(null)
    val meteredConnection: StateFlow<Boolean?> = _meteredConnection.asStateFlow()

    fun setMeteredConnection(value: Boolean?) {
        _meteredConnection.value = value
    }

    /**
     * [effectiveAudioQuality] against the live connection, as an observable.
     *
     * Derived from [meteredConnection] and the two per-network settings, so a
     * settings change or a network change both re-evaluate it without anything
     * having to remember to ask again. "Not known yet" reads as the Wi-Fi
     * setting, which is the conservative reading for an app that starts on
     * Wi-Fi.
     */
    val effectiveAudioQualityFlow: StateFlow<AudioQuality> =
        combine(_meteredConnection, _audioQualityWifi, _audioQualityCellular) { metered, wifi, cellular ->
            if (metered == true) cellular else wifi
        }.stateIn(
            CoroutineScope(SupervisorJob() + Dispatchers.Default),
            SharingStarted.Eagerly,
            effectiveAudioQuality(_meteredConnection.value == true),
        )

    const val DEFAULT_CACHE_LIMIT_BYTES = 512L * 1024 * 1024
    const val MAX_CACHE_LIMIT_BYTES = 10L * 1024 * 1024 * 1024
    const val MAX_PINNED_PLAYLISTS = 5

    private const val OLD_LYRICS_DEFAULT = "BETTER,PLUS,SIMP,LRCLIB"
    private const val UNCONFIGURED_LYRICS_SOURCES = "\u0000unconfigured"

    /** Every source name this build has offered; see [adoptNewLyricsSources]. */
    private const val KEY_LYRICS_KNOWN_SOURCES = "lyrics_known_sources"

    private fun defaultLyricsSourcesJoined(): String =
        LyricsSource.entries.filter { it in defaultEnabledLyricsSources() }.joinToString(",") { it.name }

    private fun readLyricsSourcesPref(): String {
        val stored = settings.getString("lyrics_sources", UNCONFIGURED_LYRICS_SOURCES)
        if (stored == UNCONFIGURED_LYRICS_SOURCES) {
            val defaults = defaultLyricsSourcesJoined()
            settings.putString("lyrics_sources", defaults)
            markLyricsSourcesKnown()
            return defaults
        }
        if (stored == OLD_LYRICS_DEFAULT) {
            // This exact value was the old built-in default, not an explicit
            // choice. New defaults omit the provider-wide third-party block.
            val defaults = defaultLyricsSourcesJoined()
            settings.putString("lyrics_sources", defaults)
            markLyricsSourcesKnown()
            return defaults
        }
        val migrated = persistLyricsSources(stored)
        if (migrated != stored && stored.isNotEmpty()) settings.putString("lyrics_sources", migrated)
        return adoptNewLyricsSources(migrated.ifEmpty { stored })
    }

    /**
     * Switch on sources an upgrade added, and leave switched-off ones off.
     *
     * The stored list is a record of what somebody decided about the sources that
     * existed when they decided it. A source added by a later build was not one
     * they ever had the chance to switch off, so reading the list literally left
     * every new provider dark on every existing install — and with it the ISRC
     * pass, which is run by [LyricsSource.BINI_LYRICS] and improves the match for
     * the sources that *were* enabled. The feature would have shipped and done
     * nothing for anyone who had ever opened these settings.
     *
     * The two cases are told apart by [KEY_LYRICS_KNOWN_SOURCES], the list of
     * names this build has ever offered: a source absent from it is new, and one
     * present in it that the user removed stays removed.
     */
    private fun adoptNewLyricsSources(current: String): String {
        val known = settings.getString(KEY_LYRICS_KNOWN_SOURCES, "")
            .split(",").mapNotNull { LyricsSource.fromName(it) }.toSet()
        val everything = LyricsSource.entries.toSet()
        if (known.containsAll(everything)) return current
        val fresh = (everything - known) - LyricsSource.SIMP_MUSIC
        val enabled = parseLyricsSources(current) + fresh
        val joined = enabled.joinToString(",") { it.name }
        settings.putString("lyrics_sources", joined)
        markLyricsSourcesKnown()
        return joined
    }

    private fun markLyricsSourcesKnown() {
        settings.putString(
            KEY_LYRICS_KNOWN_SOURCES,
            LyricsSource.entries.joinToString(",") { it.name },
        )
    }

    private fun readLyricsSourceOrderPref(): String {
        val stored = settings.getString("lyrics_source_order", defaultLyricsSourcesJoined())
        val migrated = persistLyricsSourceOrder(stored)
        if (migrated != stored) settings.putString("lyrics_source_order", migrated)
        return migrated
    }

    private fun persistLyricsSources(raw: String): String =
        parseLyricsSources(raw).joinToString(",") { it.name }

    private fun persistLyricsSourceOrder(raw: String): String =
        parseLyricsSourceOrder(raw).joinToString(",") { it.name }

    private fun parseLyricsSources(raw: String): Set<LyricsSource> {
        if (raw.isBlank()) return emptySet()
        if (raw == OLD_LYRICS_DEFAULT) return defaultEnabledLyricsSources()
        return raw.split(",").mapNotNull { LyricsSource.fromName(it) }.toSet()
    }

    /**
     * Saved order, with anything new appended.
     *
     * No migration needed, and deliberately so: the order is a preference about
     * sources that already exist, so a source added later simply lands at the
     * end. The *enabled set* is the one that needs [adoptNewLyricsSources],
     * because there a missing name means "off" and a new source would never be
     * switched on at all.
     */
    private fun parseLyricsSourceOrder(raw: String): List<LyricsSource> {
        if (raw.isBlank() || raw == OLD_LYRICS_DEFAULT) return LyricsSource.entries
        val saved = raw.split(",").mapNotNull { LyricsSource.fromName(it) }
        return saved + LyricsSource.entries.filter { it !in saved }
    }
}
