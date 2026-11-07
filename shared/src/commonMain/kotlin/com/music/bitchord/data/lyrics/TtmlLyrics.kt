package com.music.bitchord.data.lyrics

/**
 * Apple Music TTML — `<p>` lines with timed `<span>` syllables.
 * A tag scan keeps nested spans balanced without adding a platform XML parser.
 */
object TtmlLyrics {

    private val P = Regex(
        """<p\b([^>]*)>(.*?)</p>""",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )
    private val TAG = Regex(
        """<(/?)([a-z][\w:.-]*)\b((?:"[^"]*"|'[^']*'|[^'">])*)>""",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )
    private val BEGIN = Regex("""begin="([^"]+)"""")
    private val END = Regex("""end="([^"]+)"""")
    private val ROLE = Regex("""ttm:role="([^"]+)"""")
    /**
     * The voice that sang a line.
     *
     * Matched by its qualified name, prefix and all: the same attribute appears as
     * `ttm:agent` under a namespaced document and bare `agent` under one that
     * declares no prefix, and the two are the same attribute.
     */
    private val AGENT = Regex("""\bttm:agent="([^"]+)"|\bagent="([^"]+)"""")
    private val AGENT_DECL = Regex("""<\s*(?:ttm:)?agent\b([^>]*)>""", RegexOption.IGNORE_CASE)
    private val AGENT_ID = Regex("""\bxml:id="([^"]+)"|\bid="([^"]+)"""")
    private val AGENT_TYPE = Regex("""\btype="([^"]+)""")

    fun parse(ttml: String): List<LyricLineDto> {
        // The voices are worked out over the whole document, because which side a
        // line is sung from depends on whose turn it is — the alternation is a
        // property of the song, not of a line — so this is a second pass over the
        // lines already parsed rather than a per-line decision.
        val types = agentTypes(ttml)
        val parsed = parseLines(ttml)
        val sides = lineAlignments(parsed.map { it.second }, types)
        val placed = parsed.mapIndexed { index, (line, _) ->
            line.copy(alignment = sides[index])
        }
        // After the sides, not before: the gaps this fills in are instrumental
        // stretches that belong to nobody, and giving one the side of the line it
        // follows would put an empty row in the middle of a duet.
        return placed.withInstrumentalGaps()
    }

    /**
     * The `ttm:agent` declarations in the head, as id to type.
     *
     * Only the id is on the line itself, so this is where a declared type comes
     * from. A document that declares none is handled by the two reserved ids and
     * by treating anything else as a person — see [lineAlignments].
     */
    private fun agentTypes(ttml: String): Map<String, String> {
        val out = HashMap<String, String>()
        AGENT_DECL.findAll(ttml).forEach { m ->
            val attrs = m.groupValues[1]
            val id = (AGENT_ID.find(attrs)?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } })
                ?.takeIf { it.isNotEmpty() } ?: return@forEach
            val type = AGENT_TYPE.find(attrs)?.groupValues?.get(1)?.trim()?.lowercase()
                ?.takeIf { it.isNotEmpty() } ?: return@forEach
            out[id] = type
        }
        return out
    }

    /** Every `<p>`, with the voice that sang it, before any sides are decided. */
    private fun parseLines(ttml: String): List<Pair<LyricLineDto, String?>> {
        return P.findAll(ttml).mapNotNull { p ->
            val attrs = p.groupValues[1]
            val role = ROLE.find(attrs)?.groupValues?.get(1).orEmpty()
            if (role == "x-translation" || role == "x-roman") return@mapNotNull null
            val inner = p.groupValues[2]
            val content = parseContent(inner)
            val lead = wordsFromRuns(content.lead)
            val backing = wordsFromRuns(content.backing)
            val pBegin = time(BEGIN.find(attrs)?.groupValues?.get(1))
            val pEnd = time(END.find(attrs)?.groupValues?.get(1))
            val background = backing.takeIf { it.isNotEmpty() }?.let {
                LyricLineDto(
                    timeMs = it.first().startMs,
                    text = it.joinToString(" ") { w -> w.text },
                    words = it,
                )
            }
            val agent = AGENT.find(attrs)
                ?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } }
                ?.takeIf { it.isNotEmpty() }
            if (lead.isNotEmpty()) {
                LyricLineDto(
                    timeMs = minOf(pBegin ?: lead.first().startMs, lead.first().startMs),
                    text = lead.joinToString(" ") { it.text },
                    words = lead,
                    background = background,
                ) to agent
            } else {
                val text = content.plain.trim()
                if (text.isEmpty() || pBegin == null) null
                else LyricLineDto(pBegin, text, sungUntilMs = pEnd?.takeIf { it > pBegin }, background = background) to agent
            }
        }.sortedBy { it.first.timeMs }.toList()
    }

    private data class SpanTiming(val id: Int, val begin: Long, val end: Long)
    private data class SpanContext(
        val timing: SpanTiming? = null,
        val background: Boolean = false,
        val suppressed: Boolean = false,
    )
    private data class Content(
        val lead: MutableList<TimedRun> = mutableListOf(),
        val backing: MutableList<TimedRun> = mutableListOf(),
        var plain: String = "",
    )

    /**
     * A span can wrap other timed spans, or just style part of a timed word.
     * Matching through the first closing tag loses both cases: a wrapper steals
     * its first child's timing, and its remaining `</span>` becomes sung text.
     * Inherit timing/role through a stack, emitting only the text between tags.
     */
    private fun parseContent(inner: String): Content {
        val out = Content()
        val stack = mutableListOf<SpanContext>()
        val plain = StringBuilder()
        val leading = StringBuilder()
        val backingLeading = StringBuilder()
        var lastLeadTiming: Int? = null
        var lastBackingTiming: Int? = null

        fun append(raw: String) {
            val context = stack.lastOrNull() ?: SpanContext()
            if (context.suppressed || raw.isEmpty()) return
            val text = decode(raw)
            if (!context.background) plain.append(text)
            val runs = if (context.background) out.backing else out.lead
            val pending = if (context.background) backingLeading else leading
            val timing = context.timing
            val previous = runs.lastOrNull()
            val sameTiming = timing?.id == if (context.background) lastBackingTiming else lastLeadTiming
            if (previous != null && (timing == null || sameTiming)) {
                runs[runs.lastIndex] = previous.copy(raw = previous.raw + text)
            } else if (timing != null) {
                runs += TimedRun(timing.begin, timing.end, pending.toString() + text)
                pending.clear()
                if (context.background) lastBackingTiming = timing.id else lastLeadTiming = timing.id
            } else {
                pending.append(text)
            }
        }

        var previousEnd = 0
        TAG.findAll(inner).forEach { tag ->
            append(inner.substring(previousEnd, tag.range.first))
            previousEnd = tag.range.last + 1
            when (tag.groupValues[2].lowercase()) {
                "span" -> {
                    if (tag.groupValues[1].isNotEmpty()) {
                        if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
                    } else {
                        val attrs = tag.groupValues[3]
                        val parent = stack.lastOrNull() ?: SpanContext()
                        val role = ROLE.find(attrs)?.groupValues?.get(1)
                        val begin = time(BEGIN.find(attrs)?.groupValues?.get(1))
                        val end = time(END.find(attrs)?.groupValues?.get(1))
                        val timing = begin?.let {
                            SpanTiming(tag.range.first, it, end ?: parent.timing?.end ?: it + 200)
                        } ?: parent.timing
                        if (!attrs.trimEnd().endsWith('/')) {
                            stack += SpanContext(
                                timing = timing,
                                background = parent.background || role == "x-bg",
                                suppressed = parent.suppressed || role == "x-translation" || role == "x-roman",
                            )
                        }
                    }
                }
                "br" -> if (tag.groupValues[1].isEmpty()) append("\n")
            }
        }
        append(inner.substring(previousEnd))
        out.plain = plain.toString()
        return out
    }

    internal fun time(value: String?): Long? {
        val raw = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (raw.endsWith("ms")) return raw.dropLast(2).toDoubleOrNull()?.toLong()
        val stripped = raw.removeSuffix("s")
        val parts = stripped.split(':')
        val seconds = when (parts.size) {
            1 -> parts[0].toDoubleOrNull()
            2 -> parts[0].toDoubleOrNull()?.let { m -> parts[1].toDoubleOrNull()?.let { m * 60 + it } }
            3 -> parts[0].toDoubleOrNull()?.let { h ->
                parts[1].toDoubleOrNull()?.let { m ->
                    parts[2].toDoubleOrNull()?.let { h * 3600 + m * 60 + it }
                }
            }
            else -> null
        } ?: return null
        return (seconds * 1000).toLong()
    }

    private fun decode(text: String): String = EnhancedLrc.decodeEntities(text)
}
