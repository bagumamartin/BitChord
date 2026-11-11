package com.music.bitchord.data.lyrics

/**
 * Which lyric lines are being sung right now, and how far ahead the list should
 * scroll to show them. Upstream `LyricFocus.kt` and the `scrollLead` beside it,
 * ported whole and kept in the same place — a separate file from the panel,
 * because these are two questions about a list of lines and nothing to do with
 * how a line is drawn.
 */
object LyricFocus {

    /**
     * How far ahead of the playhead the list scrolls, at least.
     *
     * Not zero: a list that scrolls *to* the line being sung puts the next line
     * below the fold, so the reader is always one line behind and the scroll
     * spends the whole song catching up. Leading means the next line is on screen
     * before it is sung.
     */
    const val SCROLL_LEAD_MIN_MS: Long = 350L

    /**
     * …and at most.
     *
     * A long instrumental would otherwise scroll far enough ahead to park the
     * line being sung at the very top and leave a screen of upcoming words, which
     * reads as having jumped somewhere rather than as following the song.
     */
    const val SCROLL_LEAD_MAX_MS: Long = 500L

    /**
     * The lines that are being sung at [positionMs].
     *
     * Usually one, and the latest line whose stamp has passed. But a line that
     * says when it ends keeps its place until it actually ends — including after
     * the *next* line's stamp has arrived, which is the case that matters: a line
     * that runs past the next stamp used to lose its highlight the moment the
     * next timestamp was reached, so the tail of it was never shown as sung.
     *
     * That is also how a duet stays legible: the answering line overlaps the lead
     * and both are being sung at once.
     *
     * A line with no known end is only active while it is the latest — nothing
     * says how long it lasts, so holding it would hold it for ever. A gap is
     * never active at all, however its timestamp falls.
     */
    fun activeRows(lines: List<LyricLineDto>, positionMs: Long): List<Int> {
        // An unsynced transcript answers nothing at all. Every stamp is zero, so
        // the search below would find the *last* line for any position and light
        // it up for the whole song. Upstream guards this at the call site; here it
        // is guarded inside, because a function called "which lines are being
        // sung" that answers "one of them" for a transcript with no times is a
        // trap for every caller rather than for one.
        if (!isSynced(lines)) return emptyList()
        val starts = startTimes(lines)
        val latest = starts.indexOfLast { it <= positionMs }
        if (latest < 0) return emptyList()
        return (0..latest).filter { index ->
            val line = lines[index]
            !line.isGap && (index == latest || (
                !line.isGap &&
                    (line.hasKnownEnd || line.background?.hasKnownEnd == true) &&
                    starts[index] <= positionMs && positionMs < line.endMs
                ))
        }
    }

    /**
     * How far ahead of the playhead to scroll, in milliseconds.
     *
     * The gap to the next line, bounded: long enough that the next line arrives
     * before it is sung, short enough that an instrumental does not scroll the
     * list halfway down.
     *
     * Before the first line there is no current line to measure a run-up from,
     * and the minimum is the answer — a track paused at 0:00 whose words start a
     * few seconds in is every track that opens on an intro.
     */
    fun scrollLead(lines: List<LyricLineDto>, positionMs: Long): Long {
        val starts = startTimes(lines)
        val current = starts.indexOfLast { it <= positionMs }
        if (current < 0) return SCROLL_LEAD_MIN_MS
        if (current + 1 >= lines.size) return SCROLL_LEAD_MIN_MS
        val gap = starts[current + 1] - lines[current].endMs
        return gap.coerceIn(SCROLL_LEAD_MIN_MS, SCROLL_LEAD_MAX_MS)
    }

    /**
     * The line the list should be showing, which is the first of the active ones.
     *
     * The *first*, not the last: with a duet the lead comes before the answer, and
     * scrolling to the answer would put the lead off the top of the screen while
     * it was still the line being sung.
     */
    fun leadRow(lines: List<LyricLineDto>, positionMs: Long): Int {
        val active = activeRows(lines, positionMs)
        if (active.isNotEmpty()) return active.first()
        if (!isSynced(lines)) return -1
        val starts = startTimes(lines)
        val reach = positionMs + scrollLead(lines, positionMs)
        return lines.indices.lastOrNull { !lines[it].isGap && starts[it] <= reach } ?: -1
    }

    /** Whether any line or word carries a real timestamp, rather than a transcript. */
    fun isSynced(lines: List<LyricLineDto>): Boolean = lines.any { line ->
        line.timeMs > 0L || line.words.any { it.startMs > 0L || it.endMs > 0L } ||
            line.background?.let { background ->
                background.timeMs > 0L || background.words.any { it.startMs > 0L || it.endMs > 0L }
            } == true
    }

    /**
     * When each line starts, for placing the playhead among them.
     *
     * A lyric the app is timing itself is partly timed for a while: some lines
     * have been heard, the rest still read zero. Taken at face value a zero is
     * "already started", so the *last* untimed line in the song always counted
     * as the latest line passed, and the highlight leapt to a chorus minutes
     * ahead and back again each time a nearer line was timed. An untimed line
     * is instead placed between the timed lines around it, in proportion to
     * its position; past the last timed line, a few seconds a line after it.
     * A fully timed document comes back unchanged.
     */
    fun startTimes(lines: List<LyricLineDto>): LongArray {
        val raw = LongArray(lines.size) { lineStartMs(lines[it]) }
        // Line 0 at zero is the top of the song either way.
        val known = BooleanArray(lines.size) { it == 0 || raw[it] > 0L }
        if (known.all { it }) return raw
        val starts = raw.copyOf()
        var previous = 0
        var index = 1
        while (index < lines.size) {
            if (known[index]) {
                previous = index
                index += 1
                continue
            }
            var next = index
            while (next < lines.size && !known[next]) next += 1
            val base = raw[previous]
            for (missing in index until next) {
                val steps = (missing - previous).toLong()
                starts[missing] = if (next < lines.size) {
                    base + (raw[next] - base).coerceAtLeast(0L) * steps / (next - previous)
                } else {
                    base + UNTIMED_LINE_MS * steps
                }
            }
            index = next
        }
        return starts
    }

    /** About how long a sung line lasts, for lines after the last timed one. */
    private const val UNTIMED_LINE_MS: Long = 4_000L

    /** A missing line stamp falls back to the first word's timestamp. */
    private fun lineStartMs(line: LyricLineDto): Long = if (line.timeMs == 0L) {
        line.words.minOfOrNull { it.startMs }
            ?: line.background?.words?.minOfOrNull { it.startMs }
            ?: line.timeMs
    } else {
        line.timeMs
    }
}
