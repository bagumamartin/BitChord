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

    @Test
    fun `a repeated chorus line takes the words sung in its own slot`() {
        val source = listOf(
            LyricLineDto(10_000, "Let me know now if you okay"),
            LyricLineDto(14_000, "Text, call if you okay"),
            LyricLineDto(18_000, "Let me know now if you okay"),
        )
        fun phrase(startMs: Long, vararg words: String) = words.mapIndexed { index, word ->
            LyricWordObservation(startMs + index * 300L, startMs + index * 300L + 250L, word, 0.9)
        }
        // The first line is sung too faintly to hear; only the repeat is heard.
        val heard = phrase(14_100, "text", "call", "if", "you", "okay") +
            phrase(18_100, "let", "me", "know", "now", "if", "you", "okay")

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertTrue(aligned[0].words.isEmpty(), "the first line must not borrow the repeat's words")
        assertEquals(14_100, aligned[1].words.first().startMs)
        assertEquals(18_100, aligned[2].words.first().startMs)
    }

    private fun sung(startMs: Long, vararg words: String) = words.mapIndexed { index, word ->
        LyricWordObservation(startMs + index * 300L, startMs + index * 300L + 250L, word, 0.9)
    }

    @Test
    fun `an untimed line does not take a repeat of its words a minute later`() {
        val source = listOf(
            LyricLineDto(0, "Baby are you okay"),
            LyricLineDto(0, "Let me know now if you okay"),
            LyricLineDto(0, "Kiss it all away make it okay"),
        )
        // The second line was not heard in its place; the chorus repeat was.
        val heard = sung(1_000, "baby", "are", "you", "okay") +
            sung(9_000, "kiss", "it", "all", "away", "make", "it", "okay") +
            sung(75_000, "let", "me", "know", "now", "if", "you", "okay")

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertEquals(1_000, aligned[0].timeMs)
        assertTrue(aligned[1].words.isEmpty(), "line 2 must not jump to the repeat at 1:15")
        assertEquals(9_000, aligned[2].timeMs)
    }

    @Test
    fun `a line is never timed after the timed line below it`() {
        val source = listOf(
            LyricLineDto(0, "Baby are you okay"),
            LyricLineDto(0, "Let me know now if you okay"),
            LyricLineDto(
                0, "Text call if you okay",
                words = listOf(
                    LyricWordDto(4_860, 5_100, "Text"), LyricWordDto(5_100, 5_400, "call"),
                    LyricWordDto(5_400, 5_700, "if"), LyricWordDto(5_700, 6_000, "you"),
                    LyricWordDto(6_000, 6_480, "okay"),
                ),
            ),
        )
        val heard = sung(600, "baby", "are", "you", "okay") +
            sung(11_621, "let", "me", "know", "now", "if", "you", "okay")

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertTrue(aligned[1].words.isEmpty(), "line 2 at 0:11 would come after line 3 at 0:04")
        val starts = aligned.map { it.timeMs }.filter { it > 0 }
        assertEquals(starts.sorted(), starts)
    }

    @Test
    fun `a line is placed by the words the recognizer heard even when misheard`() {
        val source = listOf(
            LyricLineDto(0, "Because what you feel is real, yeah"),
            LyricLineDto(0, "And you deserve to glow up, yeah"),
        )
        // "'Cause" for "Because", "you're high" for "is real", "glo" for "glow".
        val heard = sung(1_000, "'cause", "what", "you", "feel", "you're", "high", "yeah") +
            sung(4_000, "you", "deserve", "the", "glo", "up")

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertEquals(1_000, aligned[0].timeMs)
        assertEquals(source[0].text.split(" "), aligned[0].words.map { it.text })
        assertEquals(4_000, aligned[1].words[1].startMs, "\"you\" is the second word of the line")
        assertTrue(aligned[1].words[0].startMs < aligned[1].words[1].startMs)
    }

    @Test
    fun `a line between two placed lines is placed by one clear word`() {
        val source = listOf(
            LyricLineDto(0, "Baby are you okay"),
            LyricLineDto(0, "Text call if you okay"),
            LyricLineDto(0, "Kiss it all away make it okay"),
        )
        val heard = sung(1_000, "baby", "are", "you", "okay") +
            sung(3_500, "that's", "gonna", "be", "okay") +
            sung(6_000, "kiss", "it", "all", "away", "make", "it", "okay")

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertEquals(4_400, aligned[1].words.last().startMs)
        val starts = aligned.map { it.timeMs }
        assertEquals(starts.sorted(), starts)
    }

    @Test
    fun `an unspaced script is matched character by character`() {
        val source = listOf(LyricLineDto(0, "我爱你中国"), LyricLineDto(0, "君が代は"))
        val heard = listOf(
            LyricWordObservation(1_000, 1_400, "我爱", 0.9),
            LyricWordObservation(1_400, 1_600, "你", 0.9),
            LyricWordObservation(1_600, 2_000, "中國", 0.9),
            LyricWordObservation(3_000, 3_800, "君が代は", 0.9),
        )

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertEquals(1_000, aligned[0].timeMs)
        // 國 is heard for 国; the other four characters place the line.
        assertTrue(aligned[0].words.single().endMs >= 1_800)
        assertEquals(3_000, aligned[1].timeMs)
    }

    @Test
    fun `the platform fold matches words written with and without diacritics`() {
        val source = listOf(LyricLineDto(0, "Ọmọ mi dára gan an"))
        val heard = sung(2_000, "omo", "mi", "dara", "gan", "an")
        val strip = mapOf('ọ' to 'o', 'á' to 'a', 'Ọ' to 'o')
        val fold: (String) -> String = { text -> text.lowercase().map { strip[it] ?: it }.joinToString("") }

        assertEquals(2_000, LyricsAudioAlignment.align(source, heard, fold).first().timeMs)
        assertEquals(2_300, LyricsAudioAlignment.align(source, heard, fold).first().words[1].startMs)
    }

    @Test
    fun `a line heard only in its second place goes to the second twin`() {
        val source = listOf(
            LyricLineDto(0, "You know I was there for you"),
            LyricLineDto(0, "When nobody else was there for you"),
            LyricLineDto(0, "You know I used to care for you"),
            LyricLineDto(0, "See baby I was there for you"),
            LyricLineDto(0, "When nobody else was there for you"),
            LyricLineDto(0, "So do not act like it is easy"),
        )
        // Line 2 was not heard; its twin, line 5, was.
        val heard = sung(1_000, "you", "know", "i", "was", "there", "for", "you") +
            sung(6_000, "you", "know", "i", "used", "to", "care", "for", "you") +
            sung(9_000, "see", "baby", "i", "was", "there", "for", "you") +
            sung(12_000, "when", "nobody", "else", "was", "there", "for", "you") +
            sung(15_000, "so", "do", "not", "act", "like", "it", "is", "easy")

        val aligned = LyricsAudioAlignment.align(source, heard)

        assertEquals(12_000, aligned[4].timeMs)
        assertTrue(aligned[1].words.isEmpty() || aligned[1].timeMs < 6_000)
    }
}
