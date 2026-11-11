package com.music.bitchord.data.lyrics

import kotlin.math.abs

/** Matching and timing checks shared by the provider adapters. */
internal object LyricsMatching {

    private const val CANDIDATE_DURATION_TOLERANCE_MS = 12_000L
    private const val EXTRA_DURATION_TOLERANCE_MS = 45_000L
    private const val MINIMUM_COVERAGE = 0.5
    private const val MINIMUM_SHORTFALL_MS = 90_000L
    private const val MINIMUM_TRACK_MS = 60_000L
    private const val LAST_WORD_FALLBACK_MS = 800L
    private const val MINIMUM_AGREEMENT_TOKENS = 12
    private const val MINIMUM_DOCUMENT_JACCARD = 0.55
    private const val MINIMUM_SMALLER_DOCUMENT_COVERAGE = 0.78

    /** A score only exists when the candidate is plausibly the requested recording. */
    fun candidateScore(
        wantedTitle: String,
        wantedArtist: String,
        wantedDurationMs: Long,
        candidateTitle: String?,
        candidateArtist: String?,
        candidateDurationMs: Long = 0L,
        requireArtist: Boolean = false,
    ): Int? {
        val title = normalizedTitle(candidateTitle.orEmpty())
        val wanted = normalizedTitle(wantedTitle)
        if (wanted.isNotEmpty() && title.isNotEmpty() && !titlesMatch(wanted, title)) return null
        if (requireArtist && wantedArtist.isNotBlank() && candidateArtist.isNullOrBlank()) return null

        val artistMatches = wantedArtist.isNotBlank() && !candidateArtist.isNullOrBlank() &&
            artistsMatch(wantedArtist, candidateArtist)
        if (wantedArtist.isNotBlank() && !candidateArtist.isNullOrBlank() && !artistMatches) return null
        if (wanted.isEmpty() && !artistMatches) return null
        if (wanted.isNotEmpty() && title.isEmpty()) return null

        val durationDistance = if (wantedDurationMs > 0 && candidateDurationMs > 0) {
            abs(candidateDurationMs - wantedDurationMs)
        } else {
            0L
        }
        if (durationDistance > CANDIDATE_DURATION_TOLERANCE_MS) return null

        var score = when {
            wanted.isEmpty() -> 0
            wanted == title -> 100
            else -> 80
        }
        if (artistMatches) score += 60
        if (wantedDurationMs > 0 && candidateDurationMs > 0) {
            score += when {
                durationDistance <= 2_000L -> 20
                durationDistance <= 6_000L -> 12
                else -> 4
            }
        }
        return score
    }

    /**
     * Whether a lyric's script can belong to this track. A title and artist
     * written only in Latin letters with lyrics that are mostly Hangul, kana or
     * Han is a different song that shares a title (Sean Paul's "No One" against
     * Lee Hi's). Mixed tracks — K-pop with English hooks, or a title in its own
     * script — pass, because the check only fires when the metadata has none of
     * the lyric's script at all.
     */
    fun scriptFits(title: String, artist: String, lines: List<LyricLineDto>): Boolean {
        if ((title + artist).any(::isEastAsian)) return true
        var eastAsian = 0
        var letters = 0
        lines.forEach { line ->
            line.text.forEach { c ->
                if (c.isLetter()) {
                    letters++
                    if (isEastAsian(c)) eastAsian++
                }
            }
        }
        return letters == 0 || eastAsian.toDouble() / letters < 0.3
    }

    private fun isEastAsian(c: Char): Boolean {
        val code = c.code
        return code in 0x1100..0x11FF ||  // Hangul Jamo
            code in 0x3040..0x30FF ||      // Hiragana, Katakana
            code in 0x3130..0x318F ||      // Hangul compatibility Jamo
            code in 0x3400..0x4DBF ||      // CJK extension A
            code in 0x4E00..0x9FFF ||      // CJK unified ideographs
            code in 0xAC00..0xD7AF         // Hangul syllables
    }

    /**
     * Reject a fuzzy provider response whose timeline plainly belongs to a
     * shorter or longer recording. Lenient enough for long outros and video
     * versions; strict enough to catch common same-title wrong-track hits.
     */
    fun hasPlausibleDuration(lines: List<LyricLineDto>, durationMs: Long): Boolean {
        if (durationMs < MINIMUM_TRACK_MS || lines.size < 3) return true
        val endMs = lines.maxOfOrNull(::lineEndMs) ?: return true
        if (endMs <= 0L) return true
        if (endMs > durationMs + EXTRA_DURATION_TOLERANCE_MS) return false
        return !(endMs < durationMs * MINIMUM_COVERAGE && durationMs - endMs > MINIMUM_SHORTFALL_MS)
    }

    /**
     * Whether two providers appear to describe the same lyric document. Used
     * when a video-id source supplies authoritative text and a title-matched
     * source is only being considered for its better timestamps.
     */
    fun documentsAgree(left: List<LyricLineDto>, right: List<LyricLineDto>): Boolean {
        fun tokens(lines: List<LyricLineDto>): Set<String> = lines
            .flatMap { line -> listOf(line.text, line.background?.text.orEmpty()) }
            .flatMap { words(it.lowercase()) }
            .toSet()

        val leftTokens = tokens(left)
        val rightTokens = tokens(right)
        val shared = leftTokens.intersect(rightTokens).size
        val union = leftTokens.union(rightTokens).size
        val smaller = minOf(leftTokens.size, rightTokens.size)
        // Short snippets and a repeated chorus are not enough evidence to
        // attach another provider's timeline to this recording's lyrics.
        return smaller >= MINIMUM_AGREEMENT_TOKENS &&
            shared.toDouble() / union >= MINIMUM_DOCUMENT_JACCARD &&
            shared.toDouble() / smaller >= MINIMUM_SMALLER_DOCUMENT_COVERAGE
    }

    /**
     * Repairs malformed/partial word ranges without changing valid provider
     * timestamps. Provider documents often omit the final word end; leaving it
     * equal to its start makes that word impossible to highlight.
     */
    fun normalize(lines: List<LyricLineDto>): List<LyricLineDto> {
        if (lines.isEmpty()) return lines
        val ordered = lines.withIndex()
            .filter { it.value.timeMs >= 0L }
            .sortedWith(compareBy<IndexedValue<LyricLineDto>> { effectiveLineStart(it.value) }.thenBy { it.index })
            .map { it.value }
        if (ordered.isEmpty()) return emptyList()

        val deduplicated = ordered.fold(mutableListOf<LyricLineDto>()) { result, line ->
            val previous = result.lastOrNull()
            val hasTimeline = line.timeMs > 0L || line.words.any { it.startMs > 0L || it.endMs > 0L }
            val previousHasTimeline = previous?.let {
                it.timeMs > 0L || it.words.any { word -> word.startMs > 0L || word.endMs > 0L }
            } == true
            if (previous == null || !hasTimeline || !previousHasTimeline ||
                effectiveLineStart(previous) != effectiveLineStart(line) ||
                previous.text.trim() != line.text.trim() || previous.words.size != line.words.size
            ) {
                result += line
            }
            result
        }

        return deduplicated.mapIndexed { index, line ->
            val nextLineStart = deduplicated.getOrNull(index + 1)?.let(::effectiveLineStart)
            normalizeLine(line, nextLineStart)
        }.sortedBy { it.timeMs }
    }

    private fun normalizeLine(line: LyricLineDto, nextLineStart: Long?): LyricLineDto {
        val lineEnd = line.sungUntilMs?.takeIf { it > line.timeMs }
        val orderedWords = line.words.withIndex()
            .filter { it.value.startMs >= 0L && it.value.text.isNotBlank() }
            .sortedWith(compareBy<IndexedValue<LyricWordDto>> { it.value.startMs }.thenBy { it.index })
            .map { it.value }
        val normalizedWords = orderedWords.mapIndexed { index, word ->
                val nextWordStart = orderedWords.getOrNull(index + 1)?.startMs
                val fallbackEnd = nextWordStart?.takeIf { it > word.startMs }
                    ?: lineEnd?.takeIf { it > word.startMs }
                    ?: nextLineStart?.takeIf { it > word.startMs }
                    ?: word.startMs + LAST_WORD_FALLBACK_MS
                var end = word.endMs.takeIf { it > word.startMs } ?: fallbackEnd
                if (nextWordStart != null && nextWordStart > word.startMs && end > nextWordStart) {
                    end = nextWordStart
                }
                if (lineEnd != null && lineEnd > word.startMs && end > lineEnd) end = lineEnd
                if (end < word.startMs) end = word.startMs
                if (end == word.endMs) word else word.copy(endMs = end)
            }

        val normalizedBackground = line.background?.let { normalizeLine(it, nextLineStart) }
        return line.copy(
            // Some providers mark a word-synced line with a missing/zero line
            // stamp even though its first syllable has a real timestamp.
            timeMs = if (line.timeMs == 0L) {
                normalizedWords.firstOrNull()?.startMs ?: normalizedBackground?.timeMs ?: 0L
            } else {
                line.timeMs
            },
            words = normalizedWords,
            sungUntilMs = line.sungUntilMs?.takeIf { it >= line.timeMs },
            background = normalizedBackground,
        )
    }

    private fun lineEndMs(line: LyricLineDto): Long = maxOf(
        line.timeMs,
        line.sungUntilMs ?: 0L,
        line.words.maxOfOrNull { it.endMs } ?: 0L,
        line.background?.let(::lineEndMs) ?: 0L,
    )

    private fun effectiveLineStart(line: LyricLineDto): Long =
        if (line.timeMs == 0L) {
            line.words.minOfOrNull { it.startMs }
                ?: line.background?.words?.minOfOrNull { it.startMs }
                ?: 0L
        } else {
            line.timeMs
        }

    private fun normalizedTitle(value: String): String = value.forLyricsSearch()
        .lowercase()
        .trim()

    private fun titlesMatch(wanted: String, candidate: String): Boolean {
        if (compact(wanted) == compact(candidate)) return true
        val wantedWords = words(wanted)
        val candidateWords = words(candidate)
        if (wantedWords.isEmpty() || candidateWords.isEmpty()) return false
        return wordSimilarity(wantedWords, candidateWords) >= 0.85
    }

    private fun artistsMatch(wanted: String, candidate: String): Boolean {
        val wantedParts = artistParts(wanted)
        val candidateParts = artistParts(candidate)
        if (wantedParts.any { it in candidateParts }) return true
        val wantedWords = words(normalizedArtistText(wanted)).filterNot { it in ARTICLES }
        val candidateWords = words(normalizedArtistText(candidate)).filterNot { it in ARTICLES }
        if (wantedWords.size < 2 || candidateWords.size < 2) return false
        return wordSimilarity(wantedWords, candidateWords) >= 0.85
    }

    private fun artistParts(value: String): Set<String> = value
        .artistForLyricsSearch()
        .split(ARTIST_SEPARATOR)
        .map { artistPartKey(it) }
        .filter { it.isNotEmpty() }
        .toSet()

    private fun normalizedArtistText(value: String): String = value.artistForLyricsSearch().lowercase().trim()

    private fun artistPartKey(value: String): String {
        val meaningful = words(value.lowercase()).filterNot { it in ARTICLES }
        return meaningful.joinToString("").ifEmpty { compact(value.lowercase()) }
    }

    private fun compact(value: String): String = value.filter { it.isLetterOrDigit() }

    private fun words(value: String): List<String> {
        val words = mutableListOf<String>()
        val current = StringBuilder()
        value.forEach { character ->
            if (character.isLetterOrDigit()) current.append(character)
            else if (current.isNotEmpty()) {
                words += current.toString()
                current.clear()
            }
        }
        if (current.isNotEmpty()) words += current.toString()
        return words
    }

    private fun wordSimilarity(left: List<String>, right: List<String>): Double {
        val leftCounts = left.groupingBy { it }.eachCount()
        val rightCounts = right.groupingBy { it }.eachCount()
        val keys = leftCounts.keys + rightCounts.keys
        val intersection = keys.sumOf { key -> minOf(leftCounts[key] ?: 0, rightCounts[key] ?: 0) }
        val union = keys.sumOf { key -> maxOf(leftCounts[key] ?: 0, rightCounts[key] ?: 0) }
        return if (union == 0) 0.0 else intersection.toDouble() / union
    }

    private val ARTIST_SEPARATOR = Regex(
        // `、` and `，` are how KuGou and other Chinese catalogues join artists.
        """(?i)\s*(?:,|，|、|&|;|\s+feat(?:uring)?\.?\s+|\s+ft\.?\s+|\s+with\s+|\s+x\s+)\s*""",
    )
    private val ARTICLES = setOf("a", "an", "the")
}
