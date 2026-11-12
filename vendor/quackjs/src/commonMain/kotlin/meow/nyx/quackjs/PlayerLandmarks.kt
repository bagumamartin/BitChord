package meow.nyx.quackjs

/** Validate raw landmark offsets during the index's source scan. */
internal class PlayerLandmarks(private val source: String) {
    private data class Landmark(val signature: String, val nClass: String, val signatureOffset: Int, val locations: List<Pair<Int, String>>, val identifiers: Set<Int>)
    private val candidates = mutableListOf<Landmark>()
    private val locations: List<Pair<Int, String>>
    private val actual = mutableSetOf<Pair<Int, String>>()
    private val qualified = mutableSetOf<Int>()
    private var previousTag = -1
    private var cursor = 0
    val classNames: Set<String>
    var selectedClass: String? = null
        private set

    init {
        var from = 0
        while (true) {
            val alr = source.indexOf(".set(\"alr\",\"yes\")", from)
            if (alr < 0) break
            from = alr + 1
            val beforeStart = (alr - 160).coerceAtLeast(0)
            val before = source.substring(beforeStart, alr)
            val after = source.substring(alr, (alr + 260).coerceAtMost(source.length))
            val receiver = Regex("[A-Za-z0-9_$]+$").find(before) ?: continue
            val constructors = Regex("([A-Za-z0-9_$]+)\\s*=\\s*(new\\s+g\\.([A-Za-z0-9_$]+)\\s*\\([^,()]+,\\s*!0\\s*\\))").findAll(before)
                .filter { it.groupValues[1] == receiver.value }.toList()
            val n = constructors.singleOrNull() ?: continue
            for (sig in Regex("([A-Za-z0-9_$]+)\\((\\d+),(\\d+),\\s*[A-Za-z0-9_$]+\\(\\d+,\\d+,").findAll(after)) {
                if (candidates.size >= 1024) unsupported("Player landmark limit exceeded")
                val sigOffset = alr + sig.range.first
                val constructorOffset = beforeStart + n.range.first
                val receiverOffset = beforeStart + receiver.range.first
                candidates.add(Landmark("${sig.groupValues[1]}(${sig.groupValues[2]},${sig.groupValues[3]},INPUT)", n.groupValues[3], sigOffset,
                    listOf(alr to ".", constructorOffset to receiver.value, beforeStart + n.range.first + n.value.indexOf("new", n.groupValues[1].length) to "new", receiverOffset to receiver.value, sigOffset to sig.groupValues[1]),
                    setOf(constructorOffset, receiverOffset, sigOffset)))
            }
        }
        if (candidates.isEmpty()) unsupported("Missing or ambiguous signature/n landmarks; supply PlayerHints")
        locations = candidates.flatMap { it.locations }.distinct().sortedBy { it.first }
        classNames = candidates.map { it.nClass }.toSet()
    }

    fun observe(lexer: Lexer) {
        while (cursor < locations.size && locations[cursor].first < lexer.offset) cursor++
        var matched = false
        while (cursor < locations.size && locations[cursor].first == lexer.offset) {
            val location = locations[cursor++]
            if (previousTag == ScanTags.DOT || previousTag == ScanTags.OPTIONAL || previousTag == ScanTags.NEW) qualified.add(lexer.offset)
            if (lexer.kind == 0 && lexer.end - lexer.offset == location.second.length && source.regionMatches(lexer.offset, location.second, 0, location.second.length)) {
                actual.add(location)
                matched = true
            }
        }
        previousTag = lexer.tag
        if (matched && selectedClass == null) selectedClass = candidates.firstOrNull { actual.containsAll(it.locations) }?.nClass
    }

    fun hints(): PlayerHints {
        val executable = candidates.filter { actual.containsAll(it.locations) }
        if (executable.any { landmark -> landmark.identifiers.any { it in qualified } }) unsupported("Unsupported qualified signature/n landmark")
        val valid = executable.map { it.signature to it.nClass }.toSet()
        if (valid.size != 1) unsupported("Missing or ambiguous signature/n landmarks; supply PlayerHints")
        val (signature, nClass) = valid.single()
        return PlayerHints(signature, nClass, 0)
    }

    fun requireGlobalCalls(index: SourceIndex) {
        for (landmark in candidates.filter { actual.containsAll(it.locations) }.distinctBy { it.signatureOffset }) {
            index.requireGlobalCall(landmark.signatureOffset, landmark.signature.substringBefore("("))
        }
    }
}
