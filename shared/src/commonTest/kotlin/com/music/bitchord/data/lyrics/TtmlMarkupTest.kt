package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull

class TtmlMarkupTest {
    @Test
    fun xml_comments_never_become_lyric_text_or_span_structure() {
        val line = parse("""<!-- before --><span begin="1s" end="2s">Sun<!-- provider <span> annotation </span> -->rise</span><!-- after -->""")

        assertEquals("Sunrise", line.text)
        assertEquals(listOf(LyricWordDto(1_000, 2_000, "Sunrise")), line.words)
    }

    @Test
    fun nested_formatting_does_not_leave_closing_tags_in_a_timed_word() {
        val line = parse("""<span begin="1s" end="2s">sun<span>rise</span></span>""")

        assertEquals("sunrise", line.text)
        assertEquals(listOf(LyricWordDto(1_000, 2_000, "sunrise")), line.words)
    }

    @Test
    fun untimed_wrappers_keep_all_child_words_and_their_own_times() {
        val line = parse("""<span><span><span begin="1s" end="1.4s">Morning </span><span begin="1.5s" end="2s">light</span></span></span>""")

        assertEquals("Morning light", line.text)
        assertEquals(
            listOf(LyricWordDto(1_000, 1_400, "Morning"), LyricWordDto(1_500, 2_000, "light")),
            line.words,
        )
    }

    @Test
    fun timed_children_override_the_surrounding_span_without_duplicates() {
        val line = parse("""<span begin="0.8s" end="2.5s"><span begin="1s" end="1.4s">Morning </span><span begin="1.5s" end="2s">light</span></span>""")

        assertEquals("Morning light", line.text)
        assertEquals(
            listOf(LyricWordDto(1_000, 1_400, "Morning"), LyricWordDto(1_500, 2_000, "light")),
            line.words,
        )
    }

    @Test
    fun nested_background_vocals_keep_their_role_and_timestamps() {
        val line = parse("""<span begin="1s" end="2s">Lead</span><span ttm:role="x-bg"><span><span begin="1.2s" end="1.8s">Echo</span></span></span>""")

        assertEquals("Lead", line.text)
        assertEquals(listOf(LyricWordDto(1_000, 2_000, "Lead")), line.words)
        val background = assertNotNull(line.background)
        assertEquals("Echo", background.text)
        assertEquals(listOf(LyricWordDto(1_200, 1_800, "Echo")), background.words)
    }

    @Test
    fun inter_span_markup_is_ignored_but_spacing_punctuation_and_entities_survive() {
        val line = parse("""<span begin="1s" end="1.4s">You</span><span> &amp; </span><span begin="1.5s" end="2s">me</span><i>!</i></span>""")

        assertEquals("You & me!", line.text)
        assertFalse(line.words.any { '<' in it.text || '>' in it.text })
        assertEquals(1_000L, line.words.first().startMs)
        assertEquals(2_000L, line.words.last().endMs)
    }

    @Test
    fun nested_translation_and_romanization_never_become_sung_text() {
        val line = parse("""<span><span begin="1s" end="2s">Hello</span><span ttm:role="x-translation"><span begin="1s" end="2s">Translation</span></span><span ttm:role="x-roman"><span begin="1s" end="2s">Romanization</span></span></span>""")

        assertEquals("Hello", line.text)
        assertEquals(listOf(LyricWordDto(1_000, 2_000, "Hello")), line.words)
    }

    @Test
    fun literal_comparison_symbols_remain_lyric_text() {
        val line = parse("""<span begin="1s" end="2s">1 &lt; 2 &amp; 3 &gt; 2</span>""")

        assertEquals("1 < 2 & 3 > 2", line.text)
        assertEquals(1_000L, line.words.first().startMs)
        assertEquals(2_000L, line.words.last().endMs)
    }

    private fun parse(content: String): LyricLineDto = TtmlLyrics.parse(
        """<tt><body><p begin="1s" end="2s">$content</p></body></tt>""",
    ).single()
}
