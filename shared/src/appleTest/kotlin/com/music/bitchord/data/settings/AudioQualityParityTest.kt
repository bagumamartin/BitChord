package com.music.bitchord.data.settings

import com.music.bitchord.data.sources.SourceKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AudioQualityParityTest {
    @Test
    fun stream_rungs_gate_sources_like_upstream() {
        assertEquals(128, AudioQuality.MEDIUM.maxKbps)
        assertTrue(AudioQuality.LOW.permits(SourceKind.YOUTUBE))
        assertFalse(AudioQuality.LOW.permits(SourceKind.JIOSAAVN))
        assertFalse(AudioQuality.MEDIUM.permits(SourceKind.ADDON))
        assertTrue(AudioQuality.HIGH.permits(SourceKind.JIOSAAVN))
        assertFalse(AudioQuality.HIGH.permits(SourceKind.ADDON))
        assertTrue(AudioQuality.LOSSLESS.permits(SourceKind.ADDON))
        assertEquals(AudioQuality.LOSSLESS, AudioQuality.fromName("unknown"))
    }
}
