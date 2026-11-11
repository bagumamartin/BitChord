package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class LyricsAudioAlignmentTest {
    @Test
    fun `matches recognized words to the supplied lyric text and source times`() {
        val source = listOf(
            LyricLineDto(0, "Silver birds cross the quiet sky."),
            LyricLineDto(0, "Morning light opens every door."),
        )
        val heard = listOf(
            LyricWordObservation(1_020, 1_280, "silver", 0.9),
            LyricWordObservation(1_300, 1_470, "birds", 0.9),
            LyricWordObservation(1_500, 1_690, "cross", 0.9),
            LyricWordObservation(1_720, 1_850, "the", 0.8),
            LyricWordObservation(1_900, 2_140, "quiet", 0.9),
            LyricWordObservation(2_160, 2_390, "sky", 0.9),
        )

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertEquals(source.map { it.text }, aligned.map { it.text })
        assertEquals(1_020, aligned.first().timeMs)
        assertEquals(
            listOf("Silver", "birds", "cross", "the", "quiet", "sky."),
            aligned.first().words.map { it.text },
        )
        assertEquals(1_900, aligned.first().words[4].startMs)
        assertEquals(2_390, aligned.first().words.last().endMs)
        assertTrue(aligned[1].words.isEmpty())
    }

    @Test
    fun `new chunks add later line timings while preserving the first aligned lines`() {
        val source = listOf(
            LyricLineDto(0, "Silver birds cross the quiet sky."),
            LyricLineDto(0, "Morning light opens every door."),
        )
        val firstChunk = listOf(
            LyricWordObservation(1_020, 1_280, "silver"),
            LyricWordObservation(1_300, 1_470, "birds"),
            LyricWordObservation(1_500, 1_690, "cross"),
            LyricWordObservation(1_720, 1_850, "the"),
            LyricWordObservation(1_900, 2_140, "quiet"),
            LyricWordObservation(2_160, 2_390, "sky"),
        )
        val first = LyricsAudioAlignment.align(source, firstChunk)
        val complete = LyricsAudioAlignment.align(
            source,
            firstChunk + listOf(
                LyricWordObservation(3_000, 3_250, "morning"),
                LyricWordObservation(3_270, 3_450, "light"),
                LyricWordObservation(3_470, 3_650, "opens"),
                LyricWordObservation(3_680, 3_820, "every"),
                LyricWordObservation(3_850, 4_100, "door"),
            ),
        )

        assertEquals(1_020, first[0].words.first().startMs)
        assertTrue(first[1].words.isEmpty())
        assertEquals(3_000, complete[1].words.first().startMs)
        assertNotEquals(first, complete)
    }

    @Test
    fun `unrelated and low confidence speech is never applied to the lyrics`() {
        val source = listOf(LyricLineDto(0, "Silver birds cross the quiet sky."))
        val unrelated = listOf(
            LyricWordObservation(1_000, 1_200, "winter"),
            LyricWordObservation(1_300, 1_500, "roads"),
            LyricWordObservation(1_600, 1_800, "carry"),
            LyricWordObservation(1_900, 2_100, "our"),
            LyricWordObservation(2_200, 2_400, "footsteps"),
            LyricWordObservation(2_500, 2_700, "home"),
        )
        val uncertain = unrelated.map { it.copy(confidence = 0.05) }

        assertEquals(source, LyricsAudioAlignment.align(source, unrelated))
        assertEquals(source, LyricsAudioAlignment.align(source, uncertain))
    }

    @Test
    fun `existing word timings are preserved`() {
        val line = LyricLineDto(
            1_000,
            "Silver birds",
            words = listOf(LyricWordDto(1_000, 1_250, "Silver"), LyricWordDto(1_300, 1_500, "birds")),
        )
        val unrelated = listOf(
            LyricWordObservation(10_000, 10_200, "winter"),
            LyricWordObservation(10_300, 10_500, "roads"),
        )

        assertEquals(listOf(line), LyricsAudioAlignment.align(listOf(line), unrelated))
    }

    @Test
    fun `incremental alignment retains words immediately after an aligned line`() {
        val source = listOf(
            LyricLineDto(0, "Silver birds"),
            LyricLineDto(0, "Morning light opens every door."),
        )
        val firstChunk = listOf(
            LyricWordObservation(1_000, 1_400, "silver"),
            LyricWordObservation(1_500, 2_000, "birds"),
        )
        val first = LyricsAudioAlignment.align(source, firstChunk)
        assertTrue(first[0].words.isNotEmpty())
        assertTrue(first[1].words.isEmpty())

        val complete = LyricsAudioAlignment.align(
            first,
            firstChunk + listOf(
                LyricWordObservation(2_050, 2_200, "morning"),
                LyricWordObservation(2_250, 2_400, "light"),
                LyricWordObservation(2_450, 2_600, "opens"),
                LyricWordObservation(2_650, 2_800, "every"),
                LyricWordObservation(2_850, 3_000, "door"),
            ),
        )

        assertEquals(first[0], complete[0])
        assertEquals(2_050, complete[1].words.firstOrNull()?.startMs)
        assertEquals(3_000, complete[1].words.lastOrNull()?.endMs)
    }
}
