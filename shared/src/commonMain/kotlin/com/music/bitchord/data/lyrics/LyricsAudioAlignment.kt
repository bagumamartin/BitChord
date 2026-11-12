package com.music.bitchord.data.lyrics

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** A recognizer word with its position on the source audio timeline. */
data class LyricWordObservation(
    val startMs: Long,
    val endMs: Long,
    val text: String,
    val confidence: Double = 1.0,
)

/**
 * Matches audio-recognition output back to the provider's lyric text.
 *
 * Recognition is platform-specific; this text-constrained pass is shared so a
 * recognizer cannot replace the lyric with its own transcription.
 *
 * The whole song is aligned at once: every lyric word against every heard
 * word, as one chain that only moves forward through both. A recognizer
 * mishears sung words ("glo" for "glow", "'cause" for "because"), so a line is
 * placed by the words it did hear, and the order of the lines around it
 * decides where it can be. Matching line by line needed most of a line's
 * words heard cleanly, and on music that left most lines untimed.
 *
 * A line is timed only when some of its own words were heard; the rest are
 * spaced between those. Calling [align] again with more observations refines
 * the same document.
 */
object LyricsAudioAlignment {
    private const val MIN_CONFIDENCE = 0.20
    private const val MIN_SIMILARITY = 0.74

    /** Overlap allowed with a neighbouring line that already has times. */
    private const val ORDER_TOLERANCE_MS = 300L
    /** How early or late a provider-timed line's words may be heard. */
    private const val SLOT_TOLERANCE_MS = 1_500L
    /** How long a provider-timed line with nothing timed after it may run. */
    private const val MAX_ANCHOR_DRIFT_MS = 12_000L

    /** Cost of a lyric unit the chain passes without hearing. */
    private const val LYRIC_SKIP = 0.04
    /** Cost of a heard word that matches no lyric (ad-libs, mishearing). */
    private const val HEARD_SKIP = 0.015
    /** Heard words looked back over for the previous step of the chain. */
    private const val NEAR_OBSERVATIONS = 140
    /** A step across a longer unmatched stretch than that. */
    private const val FAR_STEP = 3.0

    /** About how long one sung unit takes, and the pause a line break adds. */
    private const val UNIT_MS = 380L
    private const val LINE_BREAK_MS = 900L
    /** Slack before a gap counts as too long or too short for the lyric between. */
    private const val LATE_SLACK_MS = 4_000L
    private const val EARLY_SLACK_MS = 1_500L

    /** A word the matcher works with: one lyric token, or a CJK character of it. */
    private class LyricUnit(val key: String, val line: Int, val token: Int)

    /** A heard unit, after splitting runs of CJK characters. */
    private class Heard(val key: String, val startMs: Long, val endMs: Long, val confidence: Double)

    /** One lyric unit (or two) heard as one heard unit (or two). */
    private class Match(
        val unitFrom: Int,
        val unitTo: Int,
        val heardFrom: Int,
        val heardTo: Int,
        val score: Double,
    )

    /** Align as many lyric lines as the observations support. */
    fun align(
        lines: List<LyricLineDto>,
        observations: List<LyricWordObservation>,
    ): List<LyricLineDto> = align(lines, observations, ::defaultFold)

    /**
     * [fold] reduces a word to the form compared, e.g. without case and
     * diacritics; the platform passes its own so every script folds right.
     */
    fun align(
        lines: List<LyricLineDto>,
        observations: List<LyricWordObservation>,
        fold: (String) -> String,
    ): List<LyricLineDto> {
        if (lines.isEmpty() || observations.isEmpty()) return lines
        val heard = observations
            .asSequence()
            .filter { it.confidence >= MIN_CONFIDENCE && it.endMs > it.startMs && it.text.isNotBlank() }
            .sortedBy { it.startMs }
            .distinctBy { key(fold, it.text) to (it.startMs / 120L) }
            .flatMap { splitHeard(fold, it) }
            .toList()
        if (heard.isEmpty()) return lines

        val tokens = lines.map { lyricTokens(it.text) }
        val fixed = BooleanArray(lines.size) { index ->
            val count = tokens[index].size
            count > 0 && lines[index].words.size >= count &&
                lines[index].words.take(count).all { it.endMs > it.startMs }
        }
        val units = ArrayList<LyricUnit>()
        for (lineIndex in lines.indices) {
            if (lines[lineIndex].isGap || fixed[lineIndex]) continue
            tokens[lineIndex].forEachIndexed { tokenIndex, token ->
                for (piece in splitUnits(fold(token))) units += LyricUnit(piece, lineIndex, tokenIndex)
            }
        }
        if (units.isEmpty()) return lines

        val windows = windows(lines, fixed)
        val pairs = pairs(units, heard, windows)
        if (pairs.isEmpty()) return lines
        val chain = chain(units, heard, pairs)

        // Heard units per lyric token.
        val anchors = HashMap<Int, HashMap<Int, LongArray>>()
        for (pair in chain) {
            val startMs = heard[pair.heardFrom].startMs
            val endMs = heard[pair.heardTo].endMs
            val spread = pair.unitTo - pair.unitFrom + 1
            for (unitIndex in pair.unitFrom..pair.unitTo) {
                val unit = units[unitIndex]
                val step = (endMs - startMs) / spread
                val from = startMs + step * (unitIndex - pair.unitFrom)
                val to = if (unitIndex == pair.unitTo) endMs else from + step
                val byToken = anchors.getOrPut(unit.line) { HashMap() }
                val span = byToken[unit.token]
                byToken[unit.token] = if (span == null) longArrayOf(from, to)
                else longArrayOf(min(span[0], from), max(span[1], to))
            }
        }
        val unitsPerLine = IntArray(lines.size)
        val heardPerLine = IntArray(lines.size)
        val heardLength = IntArray(lines.size)
        for (unit in units) unitsPerLine[unit.line]++
        for (pair in chain) for (unitIndex in pair.unitFrom..pair.unitTo) {
            heardPerLine[units[unitIndex].line]++
            heardLength[units[unitIndex].line] += units[unitIndex].key.length
        }

        val placed = BooleanArray(lines.size) { lineIndex ->
            val byToken = anchors[lineIndex]
            byToken != null &&
                heardEnough(unitsPerLine[lineIndex], heardPerLine[lineIndex], heardLength[lineIndex]) &&
                // A line cannot plausibly occupy an unbounded stretch of singing.
                byToken.values.maxOf { it[1] } - byToken.values.minOf { it[0] } <=
                max(12_000L, tokens[lineIndex].size * 1_600L)
        }
        // A line with one clear word heard, between two lines placed by their
        // own words, is placed by it too: the chain already put that word
        // after the line above and before the line below, so it can only be
        // this line being sung.
        val sung = lines.indices.filter { !lines[it].isGap && tokens[it].isNotEmpty() }
        val settled = BooleanArray(lines.size) { placed[it] || fixed[it] }
        for ((position, lineIndex) in sung.withIndex()) {
            if (placed[lineIndex] || heardPerLine[lineIndex] == 0 || heardLength[lineIndex] < 3) continue
            val above = sung.getOrNull(position - 1)
            val below = sung.getOrNull(position + 1)
            if (above != null && below != null && settled[above] && settled[below]) placed[lineIndex] = true
        }

        var changed = false
        val aligned = lines.mapIndexed { lineIndex, line ->
            if (!placed[lineIndex]) return@mapIndexed line
            val byToken = anchors.getValue(lineIndex)
            val target = tokens[lineIndex]
            val timedWords = interpolate(target, byToken)
            changed = changed || timedWords != line.words
            LyricLineDto(
                timeMs = if (line.timeMs > 0L) line.timeMs else timedWords.first().startMs,
                text = line.text,
                words = timedWords,
                sungUntilMs = max(line.sungUntilMs ?: 0L, timedWords.last().endMs),
                background = line.background,
                alignment = line.alignment,
            )
        }
        return if (changed) aligned else lines
    }

    /**
     * Whether a line heard [heardUnits] of its [allUnits] is placed by its own
     * words. One clear word places a short line; longer lines need a quarter.
     */
    private fun heardEnough(allUnits: Int, heardUnits: Int, heardChars: Int): Boolean {
        if (heardUnits == 0) return false
        if (allUnits <= 3) return heardUnits >= 1 && (heardChars >= 3 || heardUnits == allUnits)
        return heardUnits >= max(2, (allUnits + 3) / 4)
    }

    /**
     * Where each line's words may be heard, from the lines that already have
     * times. A line is sung after the timed line above it and before the timed
     * line below it; a line the provider timed owns its own stretch. Choruses
     * repeat the same words every few seconds, and a match taken from the
     * next repeat put a line's words inside another line's time.
     */
    private fun windows(lines: List<LyricLineDto>, fixed: BooleanArray): Array<LongArray> {
        fun start(index: Int): Long {
            val line = lines[index]
            return if (line.timeMs > 0L) line.timeMs else line.words.minOfOrNull { it.startMs } ?: 0L
        }
        fun end(index: Int): Long = if (fixed[index]) lines[index].words.maxOf { it.endMs } else start(index)

        val nextStart = LongArray(lines.size + 1) { Long.MAX_VALUE }
        for (index in lines.indices.reversed()) {
            val here = if (fixed[index] || lines[index].timeMs > 0L) start(index) else 0L
            nextStart[index] = if (here > 0L) here else nextStart[index + 1]
        }
        val windows = Array(lines.size) { longArrayOf(0L, Long.MAX_VALUE) }
        var previousEnd = 0L
        for (index in lines.indices) {
            val later = nextStart[index + 1]
            if (lines[index].timeMs > 0L) {
                val until = if (later != Long.MAX_VALUE && later > lines[index].timeMs) later
                else lines[index].timeMs + MAX_ANCHOR_DRIFT_MS
                windows[index][0] = lines[index].timeMs - SLOT_TOLERANCE_MS
                windows[index][1] = until + SLOT_TOLERANCE_MS
            } else {
                windows[index][0] = previousEnd - ORDER_TOLERANCE_MS
                windows[index][1] = if (later == Long.MAX_VALUE) Long.MAX_VALUE else later + ORDER_TOLERANCE_MS
            }
            if (fixed[index] || lines[index].timeMs > 0L) previousEnd = max(previousEnd, end(index))
        }
        return windows
    }

    /** Every place a lyric unit plausibly was heard. */
    private fun pairs(units: List<LyricUnit>, heard: List<Heard>, windows: Array<LongArray>): List<Match> {
        val byKey = HashMap<String, MutableList<Int>>()
        heard.forEachIndexed { index, word -> byKey.getOrPut(word.key) { ArrayList() } += index }
        val pairs = ArrayList<Match>()
        fun fits(unit: LyricUnit, heardFrom: Int, heardTo: Int): Boolean {
            val window = windows[unit.line]
            return heard[heardFrom].startMs >= window[0] && heard[heardTo].endMs <= window[1]
        }
        fun weight(key: String, similarity: Double, confidence: Double): Double {
            val strength = (similarity - 0.5) * 2.0 * (0.6 + 0.4 * confidence)
            // "I", "a", "the" are heard everywhere; they place a line weakly.
            return if (key.length <= 2) strength * 0.5 else strength
        }
        // Adjacent heard words joined, for a word the recognizer split.
        val byJoined = HashMap<String, MutableList<Int>>()
        for (heardIndex in 0 until heard.size - 1) {
            val joined = heard[heardIndex].key + heard[heardIndex + 1].key
            if (joined.length >= 5) byJoined.getOrPut(joined) { ArrayList() } += heardIndex
        }
        // Each distinct lyric word is compared with each distinct heard word once.
        val similar = HashMap<String, List<kotlin.Pair<String, Double>>>()
        for (unitIndex in units.indices) {
            val unit = units[unitIndex]
            val matches = similar.getOrPut(unit.key) {
                byKey.keys.mapNotNull { heardKey ->
                    val similarity = similarity(unit.key, heardKey)
                    if (similarity >= MIN_SIMILARITY) heardKey to similarity else null
                }
            }
            for ((heardKey, similarity) in matches) {
                for (heardIndex in byKey.getValue(heardKey)) {
                    if (!fits(unit, heardIndex, heardIndex)) continue
                    pairs += Match(unitIndex, unitIndex, heardIndex, heardIndex,
                        weight(unit.key, similarity, heard[heardIndex].confidence))
                }
            }
            // A word the recognizer split ("every day" for "everyday")…
            if (unit.key.length >= 5) {
                byJoined[unit.key]?.forEach { heardIndex ->
                    if (fits(unit, heardIndex, heardIndex + 1)) {
                        pairs += Match(unitIndex, unitIndex, heardIndex, heardIndex + 1,
                            weight(unit.key, 1.0, min(heard[heardIndex].confidence, heard[heardIndex + 1].confidence)))
                    }
                }
            }
            // …or two lyric words it heard as one ("every day" as "everyday").
            val next = units.getOrNull(unitIndex + 1)
            if (next != null && next.line == unit.line) {
                val joined = unit.key + next.key
                byKey[joined]?.forEach { heardIndex ->
                    if (fits(unit, heardIndex, heardIndex)) {
                        pairs += Match(unitIndex, unitIndex + 1, heardIndex, heardIndex,
                            weight(joined, 1.0, heard[heardIndex].confidence) * 1.5)
                    }
                }
            }
        }
        pairs.sortWith(compareBy<Match>({ it.heardFrom }, { it.unitFrom }))
        return pairs
    }

    /**
     * The best chain of pairs moving forward through both the lyric and the
     * audio, scored by how well its words match, less what it skips and how
     * far its timing strays from the lyric's pace between steps.
     */
    private fun chain(units: List<LyricUnit>, heard: List<Heard>, pairs: List<Match>): List<Match> {
        val best = DoubleArray(pairs.size)
        val previous = IntArray(pairs.size) { -1 }
        // Far steps: the best chain ending before a lyric unit, among pairs
        // whose audio ended more than NEAR_OBSERVATIONS earlier. Skip costs are
        // separable, so they are folded into the stored value.
        val far = MaxTree(units.size)
        var farCursor = 0
        // Near steps: pairs grouped by the heard word they end on, each group
        // ordered by lyric position, latest first, with its best chain so far.
        val unitTo = IntArray(pairs.size) { pairs[it].unitTo }
        val unitLine = IntArray(units.size) { units[it].line }
        val heardStart = LongArray(heard.size) { heard[it].startMs }
        val heardEnd = LongArray(heard.size) { heard[it].endMs }
        val endingAt = Array(heard.size) { ArrayList<Int>() }
        for (index in pairs.indices) endingAt[pairs[index].heardTo] += index
        val groups = Array(heard.size) { heardIndex ->
            endingAt[heardIndex].sortedByDescending { unitTo[it] }.toIntArray()
        }
        val groupBest = DoubleArray(heard.size) { Double.NEGATIVE_INFINITY }

        for (index in pairs.indices) {
            val pair = pairs[index]
            while (farCursor < index && pairs[farCursor].heardTo < pair.heardFrom - NEAR_OBSERVATIONS) {
                val done = pairs[farCursor]
                far.raise(done.unitTo, best[farCursor] + LYRIC_SKIP * done.unitTo, farCursor)
                farCursor++
            }
            var score = pair.score - LYRIC_SKIP * pair.unitFrom
            var from = -1
            val (farScore, farIndex) = far.max(pair.unitFrom - 1)
            if (farIndex >= 0) {
                val candidate = farScore - LYRIC_SKIP * (pair.unitFrom - 1) - FAR_STEP + pair.score
                if (candidate > score) { score = candidate; from = farIndex }
            }
            // Nearest first: the best step is usually close, and once found
            // the cost of what a step skips rules out most others unexamined.
            for (heardIndex in pair.heardFrom - 1 downTo max(0, pair.heardFrom - NEAR_OBSERVATIONS)) {
                val heardSkip = HEARD_SKIP * (pair.heardFrom - heardIndex - 1)
                val ceiling = groupBest[heardIndex] + pair.score - heardSkip
                if (ceiling <= score) continue
                val group = groups[heardIndex]
                // Skip to the first pair ending before this lyric unit.
                var low = 0
                var high = group.size
                while (low < high) {
                    val middle = (low + high) ushr 1
                    if (unitTo[group[middle]] >= pair.unitFrom) low = middle + 1 else high = middle
                }
                for (position in low until group.size) {
                    val before = group[position]
                    val earlierUnit = unitTo[before]
                    // Later in the group only skips more lyric.
                    if (ceiling - LYRIC_SKIP * (pair.unitFrom - earlierUnit - 1) <= score) break
                    val reach = best[before] + pair.score
                    if (reach - heardSkip - LYRIC_SKIP * (pair.unitFrom - earlierUnit - 1) <= score) continue
                    val candidate = reach - step(unitLine, heardStart, heardEnd, pairs[before], pair)
                    if (candidate > score) { score = candidate; from = before }
                }
            }
            best[index] = score
            groupBest[pair.heardTo] = max(groupBest[pair.heardTo], score)
            previous[index] = from
        }
        var end = best.indices.maxByOrNull { best[it] } ?: return emptyList()
        val chain = ArrayList<Match>()
        while (end >= 0) { chain += pairs[end]; end = previous[end] }
        chain.reverse()
        return chain
    }

    /** What moving from [from] to [to] costs: skipped words and an implausible pace. */
    private fun step(unitLine: IntArray, heardStart: LongArray, heardEnd: LongArray, from: Match, to: Match): Double {
        val skippedUnits = to.unitFrom - from.unitTo - 1
        val skippedHeard = to.heardFrom - from.heardTo - 1
        val breaks = unitLine[to.unitFrom] - unitLine[from.unitTo]
        val gapMs = heardStart[to.heardFrom] - heardEnd[from.heardTo]
        val expectedMs = UNIT_MS * skippedUnits + LINE_BREAK_MS * breaks
        val late = gapMs - expectedMs - LATE_SLACK_MS
        val early = expectedMs - gapMs - EARLY_SLACK_MS
        // Late is often right (an instrumental break), so it grows slowly; a
        // whole verse squeezed into a second is not, so early grows fast.
        val pace = when {
            late > 0 -> 2.0 * ln(1.0 + late / 4_000.0)
            early > 0 -> early / 2_000.0
            else -> 0.0
        }
        return LYRIC_SKIP * skippedUnits + HEARD_SKIP * skippedHeard + pace
    }

    /** Prefix maximum over lyric units, for the far steps. */
    private class MaxTree(size: Int) {
        private val values = DoubleArray(size + 1) { Double.NEGATIVE_INFINITY }
        private val owners = IntArray(size + 1) { -1 }

        fun raise(position: Int, value: Double, owner: Int) {
            var at = position + 1
            while (at < values.size) {
                if (value > values[at]) { values[at] = value; owners[at] = owner }
                at += at and -at
            }
        }

        /** The best value at or before [position]. */
        fun max(position: Int): kotlin.Pair<Double, Int> {
            var at = min(position + 1, values.size - 1)
            var value = Double.NEGATIVE_INFINITY
            var owner = -1
            while (at > 0) {
                if (values[at] > value) { value = values[at]; owner = owners[at] }
                at -= at and -at
            }
            return value to owner
        }
    }

    private fun interpolate(target: List<String>, heard: Map<Int, LongArray>): List<LyricWordDto> {
        val anchors = heard.keys.sorted()
        return target.indices.map { index ->
            val exact = heard[index]
            if (exact != null) {
                LyricWordDto(exact[0], max(exact[0] + 1L, exact[1]), target[index])
            } else {
                val beforeIndex = anchors.lastOrNull { it < index }
                val afterIndex = anchors.firstOrNull { it > index }
                val before = beforeIndex?.let(heard::get)
                val after = afterIndex?.let(heard::get)
                val (start, end) = when {
                    before != null && after != null -> {
                        val slots = (afterIndex!! - beforeIndex!!).toLong()
                        val step = ((after[0] - before[1]).coerceAtLeast(0L) / slots).coerceAtLeast(80L)
                        val wordStart = before[1] + step * (index - beforeIndex - 1)
                        wordStart to (wordStart + max(80L, min(step, 400L)))
                    }
                    before != null -> {
                        val wordStart = before[1] + 260L * (index - beforeIndex!! - 1)
                        wordStart to (wordStart + 240L)
                    }
                    after != null -> {
                        val wordEnd = (after[0] - 260L * (afterIndex!! - index - 1)).coerceAtLeast(0L)
                        (wordEnd - 240L).coerceAtLeast(0L) to wordEnd
                    }
                    else -> 0L to 0L
                }
                LyricWordDto(start, max(start + 1L, end), target[index])
            }
        }
    }

    private fun lyricTokens(text: String): List<String> = text
        .split(WHITESPACE)
        .map { it.trim() }
        .filter { it.isNotEmpty() }

    /** Lowercase letters and digits only; the platform's fold also drops diacritics. */
    fun defaultFold(text: String): String = text.lowercase()

    private fun key(fold: (String) -> String, text: String): String =
        canonical(fold(text).filter { it.isLetterOrDigit() })

    /**
     * Splits a folded lyric token into units: CJK and Thai are written without
     * spaces, so each of their characters is a unit; other runs stay whole.
     */
    private fun splitUnits(folded: String): List<String> {
        val out = ArrayList<String>()
        val run = StringBuilder()
        for (char in folded) {
            when {
                isUnspaced(char) -> {
                    if (run.isNotEmpty()) { out += canonical(run.toString()); run.clear() }
                    out += char.toString()
                }
                char.isLetterOrDigit() -> run.append(char)
            }
        }
        if (run.isNotEmpty()) out += canonical(run.toString())
        return out
    }

    /** A heard word as units, its time shared across any CJK characters in it. */
    private fun splitHeard(fold: (String) -> String, word: LyricWordObservation): List<Heard> {
        val units = splitUnits(fold(word.text))
        if (units.size <= 1) {
            return units.map { Heard(it, word.startMs, word.endMs, word.confidence) }
        }
        val step = (word.endMs - word.startMs) / units.size
        return units.mapIndexed { index, unit ->
            val start = word.startMs + step * index
            Heard(unit, start, if (index == units.lastIndex) word.endMs else start + step, word.confidence)
        }
    }

    private fun isUnspaced(char: Char): Boolean {
        val code = char.code
        return code in 0x3040..0x30FF || // Hiragana, Katakana
            code in 0x3400..0x4DBF || code in 0x4E00..0x9FFF || code in 0xF900..0xFAFF || // Han
            code in 0x0E00..0x0E7F || // Thai
            code in 0x0E80..0x0EFF || // Lao
            code in 0x1780..0x17FF || // Khmer
            code in 0x1000..0x109F // Myanmar
    }

    /** The spellings singers and recognizers swap for one another. */
    private fun canonical(word: String): String = ALIASES[word] ?: word

    private val ALIASES = mapOf(
        "because" to "cause", "cuz" to "cause", "cos" to "cause", "coz" to "cause", "bc" to "cause",
        "ok" to "okay", "okey" to "okay",
        "til" to "till", "until" to "till", "untill" to "till",
        "them" to "em",
        "gon" to "gonna", "goin" to "going",
        "tho" to "though", "thru" to "through", "nite" to "night", "luv" to "love",
        "ya" to "you", "yah" to "yeah", "yea" to "yeah", "ye" to "yeah",
        "lil" to "little", "imma" to "ima", "nothin" to "nothing", "somethin" to "something",
        "aint" to "aint", "wit" to "with", "da" to "the",
    )

    private fun similarity(left: String, right: String): Double {
        if (left == right) return 1.0
        if (left.isEmpty() || right.isEmpty()) return 0.0
        val shorter = min(left.length, right.length)
        val longer = max(left.length, right.length)
        if (shorter < 3 || longer - shorter > 2) return 0.0
        // "glo" for "glow", "runnin" for "running": a dropped ending.
        if (longer - shorter <= 2 && (left.startsWith(right) || right.startsWith(left))) return 0.8
        if (shorter < 4) return 0.0
        return 1.0 - editDistance(left, right).toDouble() / longer
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
