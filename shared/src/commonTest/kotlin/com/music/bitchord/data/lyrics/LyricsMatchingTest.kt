package com.music.bitchord.data.lyrics

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.decodeFromString

class LyricsMatchingTest {

    @Test
    fun `video-keyed lyric sources lead only when the track has a video id`() {
        val configured = listOf(
            LyricsSource.LRCLIB,
            LyricsSource.YOUTUBE_MUSIC,
            LyricsSource.BINI_LYRICS,
            LyricsSource.YOUTUBE_TRANSCRIPT,
            LyricsSource.SIMP_MUSIC,
        )

        assertEquals(
            listOf(
                LyricsSource.YOUTUBE_MUSIC,
                LyricsSource.YOUTUBE_TRANSCRIPT,
                LyricsSource.SIMP_MUSIC,
                LyricsSource.LRCLIB,
                LyricsSource.BINI_LYRICS,
            ),
            LyricsRepository.identityAwareOrder(configured, "abcdefghijk"),
        )
        assertEquals(configured, LyricsRepository.identityAwareOrder(configured, "local-file"))
    }

    @Test
    fun `same title by a different artist is rejected`() {
        assertNull(
            LyricsMatching.candidateScore(
                wantedTitle = "Same Title",
                wantedArtist = "The Right Band",
                wantedDurationMs = 205_000,
                candidateTitle = "Same Title",
                candidateArtist = "A Different Band",
                candidateDurationMs = 205_000,
            ),
        )
    }

    @Test
    fun `punctuation and a leading article do not block a correct match`() {
        assertNotNull(
            LyricsMatching.candidateScore(
                wantedTitle = "Don't Stop",
                wantedArtist = "Right Band",
                wantedDurationMs = 205_000,
                candidateTitle = "Don’t Stop! (Official Audio)",
                candidateArtist = "The Right Band",
                candidateDurationMs = 207.0.toLong() * 1000,
                requireArtist = true,
            ),
        )
    }

    @Test
    fun `different recording labels and large duration differences are rejected`() {
        assertNull(
            LyricsMatching.candidateScore(
                "Song (Live)", "Artist", 240_000, "Song (Remix)", "Artist", 240_000,
            ),
        )
        assertNull(
            LyricsMatching.candidateScore(
                "Song", "Artist", 240_000, "Song", "Artist", 270_000,
            ),
        )
    }

    @Test
    fun `LRC matching preserves live and remix recording identity`() {
        val baseRecording = LrcLib.Track(
            name = "Song",
            artistName = "Artist",
            duration = 240.0,
            syncedLyrics = "[00:01.00]one",
        )
        assertNull(LrcLib.candidateScore(baseRecording, "Song (Live)", "Artist", 240_000))
        assertNull(LrcLib.candidateScore(baseRecording, "Song (Remix)", "Artist", 240_000))
    }

    @Test
    fun `duplicate lines in an unsynced transcript are retained`() {
        val lines = LyricsMatching.normalize(
            listOf(
                LyricLineDto(0, "chorus"),
                LyricLineDto(0, "chorus"),
            ),
        )
        assertEquals(listOf("chorus", "chorus"), lines.map { it.text })
    }

    @Test
    fun `a response whose lyric timeline is much shorter than the track is refused`() {
        val lines = listOf(
            LyricLineDto(1_000, "one"),
            LyricLineDto(15_000, "two"),
            LyricLineDto(40_000, "three"),
        )
        assertFalse(LyricsMatching.hasPlausibleDuration(lines, 240_000))
        assertTrue(LyricsMatching.hasPlausibleDuration(lines, 80_000))
    }

    @Test
    fun `timed lyrics are borrowed only when their words agree with video lyrics`() {
        val exactVideo = listOf(
            LyricLineDto(0, "we dance beneath the orange lights tonight"),
            LyricLineDto(20_000, "we sing until the morning comes around"),
        )
        val sameSongTimed = listOf(
            LyricLineDto(0, "We dance beneath the orange lights tonight", words = listOf(LyricWordDto(0, 200, "We"))),
            LyricLineDto(20_000, "we sing until the morning comes around", words = listOf(LyricWordDto(20_000, 20_200, "we"))),
        )
        val wrongSongTimed = listOf(
            LyricLineDto(0, "we drive across the desert chasing headlights"),
            LyricLineDto(20_000, "the city keeps on calling through the night"),
        )

        assertTrue(LyricsMatching.documentsAgree(exactVideo, sameSongTimed))
        assertFalse(LyricsMatching.documentsAgree(exactVideo, wrongSongTimed))
    }

    @Test
    fun `normalization closes a provider's untimed last word`() {
        val lines = LyricsMatching.normalize(
            listOf(
                LyricLineDto(
                    timeMs = 1_000,
                    text = "hello world",
                    words = listOf(
                        LyricWordDto(1_000, 1_500, "hello"),
                        LyricWordDto(1_500, 1_500, "world"),
                    ),
                ),
            ),
        )
        assertEquals(2_300, lines.single().words.last().endMs)
    }

    @Test
    fun `LRC global offsets and single digit fractions are applied`() {
        val lines = LrcLib.parseLrc("""
            [offset:-250]
            [00:01.2]first
            [00:02.00]second
        """.trimIndent())
        assertEquals(950, lines.first().timeMs)
        assertEquals(1_750, lines.last().timeMs)
    }

    @Test
    fun `Bini decodes the search response envelope and selects a metadata match`() {
        // Trimmed synthetic data in the provider's observed wire shape. Keep a
        // URL-shaped placeholder so the fixture tests search metadata only; it
        // contains no lyrics and never fetches a live document.
        val response = lyricsJson.decodeFromString(
            BiniLyrics.Response.serializer(),
            """{"total":1,"source":"HIT-EXACT","results":[{"track_name":"Fixture Song","artist_name":"The Fixture Artist","album_name":"Fixture Album","duration":205,"isrc":"SYNTHETIC123","timing_type":"line","lyricsUrl":"https://fixture.invalid/lyrics.ttml"}]}""",
        )

        val selected = BiniLyrics.selectHit(
            response.results.orEmpty(),
            title = "Fixture Song",
            artist = "Fixture Artist",
            durationMs = 205_000,
        )

        assertEquals("SYNTHETIC123", selected?.isrc)
        assertEquals("https://fixture.invalid/lyrics.ttml", selected?.lyricsUrl)
    }

    @Test
    fun `Bini only shares an ISRC from the correctly matched hit`() {
        val hits = listOf(
            BiniLyrics.Hit("Same Title", "A Different Band", duration = 205, isrc = "WRONG"),
            BiniLyrics.Hit("Same Title", "The Right Band", duration = 205, isrc = "RIGHT"),
        )
        assertEquals(
            "RIGHT",
            BiniLyrics.selectHit(hits, "Same Title", "Right Band", 205_000)?.isrc,
        )
    }

    @Test
    fun `Bini only accepts a metadata-matched fallback when ISRC is missing`() {
        val hits = listOf(
            BiniLyrics.Hit("Same Title", "A Different Band", duration = 205),
            BiniLyrics.Hit("Same Title", "The Right Band", duration = 205),
        )
        assertEquals(
            "The Right Band",
            BiniLyrics.selectHitForIsrc(hits, "KNOWN", "Same Title", "Right Band", 205_000)?.artistName,
        )
        assertNull(
            BiniLyrics.selectHitForIsrc(
                hits.take(1), "KNOWN", "Same Title", "Right Band", 205_000,
            ),
        )
    }

    @Test
    fun `a KuGou hit by another artist with the same title is rejected`() {
        // Lee Hi's "NO ONE" came back for Sean Paul's at a matching length.
        assertNull(
            LyricsMatching.candidateScore(
                wantedTitle = "No One", wantedArtist = "Sean Paul, Amanda Reifer", wantedDurationMs = 0L,
                candidateTitle = "NO ONE (NO ONE)(Feat. B.I of iKON)", candidateArtist = "李遐怡、B.I",
                requireArtist = true,
            ),
        )
        assertNotNull(
            LyricsMatching.candidateScore(
                wantedTitle = "No One", wantedArtist = "Sean Paul & Amanda Reifer", wantedDurationMs = 0L,
                candidateTitle = "No One", candidateArtist = "Sean Paul、Amanda Reifer",
                requireArtist = true,
            ),
        )
    }

    @Test
    fun `lyrics in a script the track never uses are rejected`() {
        val korean = listOf(LyricLineDto(0, "누구 없소"), LyricLineDto(2_000, "나를 붙잡아줄 님은 없소"))
        val english = listOf(LyricLineDto(0, "When yuh bend yuh back"), LyricLineDto(2_000, "girl, when yuh"))
        assertFalse(LyricsMatching.scriptFits("No One", "Sean Paul", korean))
        assertTrue(LyricsMatching.scriptFits("No One", "Sean Paul", english))
        assertTrue(LyricsMatching.scriptFits("누구 없소 (NO ONE)", "이하이", korean))
        // English hooks in a Korean song are fine either way round.
        assertTrue(LyricsMatching.scriptFits("Dynamite", "BTS", english + LyricLineDto(4_000, "빛나")))
    }
}
