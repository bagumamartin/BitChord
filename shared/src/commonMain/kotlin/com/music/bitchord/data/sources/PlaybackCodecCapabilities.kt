package com.music.bitchord.data.sources

import com.music.bitchord.data.settings.AppSettings
import com.music.bitchord.data.settings.AudioQuality
import kotlin.concurrent.Volatile

/** Host decoder capabilities; native stereo decoding remains the default. */
object PlaybackCodecCapabilities {
    @Volatile private var appleDolbyAvailable = false
    fun setAppleDolbyAvailable(value: Boolean) { appleDolbyAvailable = value }

    /**
     * Whether the output in use right now can carry lossless audio — set by the
     * host on every route change. An addon declaring `checkValidLossless` is
     * only asked while this is true. Defaults to true: the built-in output is.
     */
    @Volatile var losslessOutput: Boolean = true
        private set
    fun setLosslessOutput(value: Boolean) { losslessOutput = value }
    /**
     * Whether a lossless stream may be taken from a source. The listener's
     * quality setting decides, not the output: as upstream, Bluetooth only sidelines
     * an addon that declares `checkValidLossless`. A FLAC re-encoded for
     * the headphones still loses less than an Opus stream re-encoded the same way.
     * Tying this to the route had let a wired output take lossless past a capped
     * mobile-data setting while Bluetooth refused it on unmetered Wi-Fi.
     */
    val allowLosslessSources: Boolean
        get() = AppSettings.effectiveAudioQuality(AppSettings.meteredConnection.value == true) == AudioQuality.LOSSLESS
    fun canRenderDolby(codec: String?, headers: Map<String, String>): Boolean =
        appleDolbyAvailable && AppSettings.dolbyAtmos.value && headers.isEmpty() &&
            codec?.lowercase() in setOf("ac3", "ac-3", "eac3", "e-ac-3", "ec-3", "ec3", "eac3-joc", "ec3-joc", "dolby-atmos")
}
