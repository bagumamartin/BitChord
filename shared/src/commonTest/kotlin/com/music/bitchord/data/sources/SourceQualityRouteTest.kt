package com.music.bitchord.data.sources

import com.music.bitchord.data.settings.AppSettings
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SourceQualityRouteTest {
    @Test fun selectedLosslessSourceRemainsEligibleOnBluetoothWithoutClaimingLosslessOutput() {
        val wifi = AppSettings.audioQualityWifi.value.name
        val cellular = AppSettings.audioQualityCellular.value.name
        val metered = AppSettings.meteredConnection.value
        val physical = PlaybackCodecCapabilities.losslessOutput
        try {
            PlaybackCodecCapabilities.setLosslessOutput(false)
            AppSettings.setAudioQualityWifi("LOSSLESS")
            AppSettings.setAudioQualityCellular("LOW")
            AppSettings.setMeteredConnection(false)
            assertTrue(PlaybackCodecCapabilities.allowLosslessSources)
            assertFalse(PlaybackCodecCapabilities.losslessOutput)

            // Moving onto capped mobile data keeps the listener's data limit.
            AppSettings.setMeteredConnection(true)
            assertFalse(PlaybackCodecCapabilities.allowLosslessSources)
            AppSettings.setAudioQualityCellular("LOSSLESS")
            assertTrue(PlaybackCodecCapabilities.allowLosslessSources)
            assertFalse(PlaybackCodecCapabilities.losslessOutput)
        } finally {
            AppSettings.setAudioQualityWifi(wifi)
            AppSettings.setAudioQualityCellular(cellular)
            AppSettings.setMeteredConnection(metered)
            PlaybackCodecCapabilities.setLosslessOutput(physical)
        }
    }

    /** A wired output carries lossless, but the data limit still applies to it. */
    @Test fun wiredOutputDoesNotBypassACappedQualitySetting() {
        val cellular = AppSettings.audioQualityCellular.value.name
        val metered = AppSettings.meteredConnection.value
        val physical = PlaybackCodecCapabilities.losslessOutput
        try {
            PlaybackCodecCapabilities.setLosslessOutput(true)
            AppSettings.setAudioQualityCellular("MEDIUM")
            AppSettings.setMeteredConnection(true)
            assertFalse(PlaybackCodecCapabilities.allowLosslessSources)
        } finally {
            AppSettings.setAudioQualityCellular(cellular)
            AppSettings.setMeteredConnection(metered)
            PlaybackCodecCapabilities.setLosslessOutput(physical)
        }
    }
}
