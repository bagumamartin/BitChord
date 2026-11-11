package com.music.bitchord.data.lyrics

/** A recognizer word with its position on the source audio timeline. */
data class LyricWordObservation(
    val startMs: Long,
    val endMs: Long,
    val text: String,
    val confidence: Double = 1.0,
)

/**
 * Matches incremental audio-recognition output back to the provider's lyric text.
 *
 * Recognition is platform-specific; this monotonic, text-constrained pass is
 * shared so a recognizer cannot replace the lyric with its own transcription.
 * Calling [align] again with more observations refines the same document and
 * leaves lines with no convincing match untouched.
 */
object LyricsAudioAlignment {
    private const val MIN_CONFIDENCE = 0.20
    private const val MAX_RECOGNIZER_INSERTIONS = 3
    private const val MAX_ANCHOR_DRIFT_MS = 12_000L

    private data class Candidate(
        val startObservation: Int,
        val endObservation: Int,
        val matched: Map<Int, LyricWordObservation>,
        val score: Double,
    )

    /** Align as many whole lyric lines as the observations currently support. */
    fun align(
        lines: List<LyricLineDto>,
        observations: List<LyricWordObservation>,
    ): List<LyricLineDto> {
        if (lines.isEmpty() || observations.isEmpty()) return lines
        val words = observations
            .asSequence()
            .filter { it.confidence >= MIN_CONFIDENCE && it.endMs > it.startMs && it.text.isNotBlank() }
            .sortedBy { it.startMs }
            .distinctBy { normalize(it.text) to (it.startMs / 120L) }
            .toList()
        if (words.size < 2) return lines

        var observationCursor = 0
        var changed = false
        val aligned = lines.map { line ->
            val target = lyricTokens(line.text)
            if (target.size < 2 || line.isGap) return@map line

            val alreadyWordTimed = line.words.size >= target.size &&
                line.words.take(target.size).all { it.endMs > it.startMs }
            if (alreadyWordTimed) {
                val lastTime = line.words.take(target.size).maxOf { it.endMs }
                observationCursor = maxOf(
                    observationCursor,
                    // The next line may start immediately after this one.
                    // Consuming a tolerance window also consumes its anchors.
                    words.indexOfLast { it.endMs <= lastTime } + 1,
                )
                return@map line
            }

            val candidate = findCandidate(target, words, observationCursor, line.timeMs)
                ?: return@map line
            val timedWords = interpolate(target, candidate.matched)
            if (timedWords.size != target.size) return@map line
            changed = changed || timedWords != line.words
            observationCursor = maxOf(observationCursor, candidate.endObservation)
            LyricLineDto(
                timeMs = if (line.timeMs > 0L) line.timeMs else timedWords.first().startMs,
                text = line.text,
                words = timedWords,
                sungUntilMs = maxOf(line.sungUntilMs ?: 0L, timedWords.last().endMs),
                background = line.background,
                alignment = line.alignment,
            )
        }
        return if (changed) aligned else lines
    }

    private fun findCandidate(
        target: List<String>,
        observed: List<LyricWordObservation>,
        cursor: Int,
        anchorMs: Long,
    ): Candidate? {
        val minMatches = if (target.size <= 3) target.size else (target.size * 0.68).toInt().coerceAtLeast(2)
        var best: Candidate? = null
        for (start in cursor until observed.size) {
            if (anchorMs > 0L && observed[start].startMs !in
                (anchorMs - MAX_ANCHOR_DRIFT_MS).coerceAtLeast(0L)..(anchorMs + MAX_ANCHOR_DRIFT_MS)
            ) continue

            var cursorInAudio = start
            var insertionCount = 0
            val matched = linkedMapOf<Int, LyricWordObservation>()
            for (targetIndex in target.indices) {
                val found = (cursorInAudio until minOf(observed.size, cursorInAudio + MAX_RECOGNIZER_INSERTIONS + 1))
                    .asSequence()
                    .mapNotNull { audioIndex ->
                        val similarity = similarity(
                            normalize(target[targetIndex]),
                            normalize(observed[audioIndex].text),
                        )
                        if (similarity >= 0.82 && observed[audioIndex].confidence >= MIN_CONFIDENCE) {
                            Triple(audioIndex, observed[audioIndex], similarity)
                        } else {
                            null
                        }
                    }
                    .maxByOrNull { it.third * observed[it.first].confidence }
                if (found == null) continue
                insertionCount += found.first - cursorInAudio
                matched[targetIndex] = found.second
                cursorInAudio = found.first + 1
            }

            if (matched.size < minMatches || 0 !in matched || target.lastIndex !in matched) continue
            if (insertionCount > target.size + 2) continue
            val first = matched.getValue(0)
            val last = matched.getValue(target.lastIndex)
            val span = last.endMs - first.startMs
            // A line cannot plausibly occupy an unbounded stretch of speech.
            if (span > maxOf(12_000L, target.size * 1_600L)) continue
            val confidence = matched.values.map { it.confidence }.average()
            val coverage = matched.size.toDouble() / target.size
            val score = coverage + confidence * 0.15 - insertionCount * 0.015
            val candidate = Candidate(start, cursorInAudio, matched, score)
            val previous = best
            if (previous == null || candidate.score > previous.score + 0.001 ||
                (kotlin.math.abs(candidate.score - previous.score) <= 0.001 && start < previous.startObservation)
            ) {
                best = candidate
            }
        }
        return best
    }

    private fun interpolate(
        target: List<String>,
        matched: Map<Int, LyricWordObservation>,
    ): List<LyricWordDto> {
        if (matched.isEmpty()) return emptyList()
        val anchors = matched.keys.sorted()
        return target.indices.map { index ->
            val exact = matched[index]
            if (exact != null) {
                LyricWordDto(exact.startMs, exact.endMs, target[index])
            } else {
                val beforeIndex = anchors.lastOrNull { it < index }
                val afterIndex = anchors.firstOrNull { it > index }
                val before = beforeIndex?.let(matched::get)
                val after = afterIndex?.let(matched::get)
                val (start, end) = when {
                    before != null && after != null && afterIndex!! - beforeIndex!! > 1 -> {
                        val slots = (afterIndex - beforeIndex).toLong()
                        val step = ((after.startMs - before.endMs).coerceAtLeast(0L) / slots).coerceAtLeast(80L)
                        val wordStart = before.endMs + step * (index - beforeIndex)
                        wordStart to (wordStart + minOf(step, 240L))
                    }
                    before != null -> {
                        val wordStart = before.endMs + 90L * (index - beforeIndex!!)
                        wordStart to (wordStart + 180L)
                    }
                    after != null -> {
                        val wordEnd = (after.startMs - 90L * (afterIndex!! - index)).coerceAtLeast(0L)
                        (wordEnd - 180L).coerceAtLeast(0L) to wordEnd
                    }
                    else -> 0L to 0L
                }
                LyricWordDto(start, maxOf(start + 1L, end), target[index])
            }
        }
    }

    private fun lyricTokens(text: String): List<String> = text
        .split(WHITESPACE)
        .map { it.trim() }
        .filter { it.isNotEmpty() }

    private fun normalize(text: String): String = text
        .lowercase()
        .filter { it.isLetterOrDigit() }

    private fun similarity(left: String, right: String): Double {
        if (left == right) return 1.0
        if (left.length < 4 || right.length < 4) return 0.0
        val distance = editDistance(left, right)
        return 1.0 - distance.toDouble() / maxOf(left.length, right.length)
    }

    private fun editDistance(left: String, right: String): Int {
        var previous = IntArray(right.length + 1) { it }
        for (i in left.indices) {
            val current = IntArray(right.length + 1)
            current[0] = i + 1
            for (j in right.indices) {
                current[j + 1] = minOf(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + if (left[i] == right[j]) 0 else 1,
                )
            }
            previous = current
        }
        return previous[right.length]
    }

    private val WHITESPACE = Regex("\\s+")
}
