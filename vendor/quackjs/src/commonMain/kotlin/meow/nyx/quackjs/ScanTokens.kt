package meow.nyx.quackjs

/** Fixed lexemes use integer tags; other identifiers keep only their source span. */
internal object ScanTags {
    const val IDENTIFIER = 256
    const val EQUAL = 61
    const val LPAREN = 40
    const val RPAREN = 41
    const val LBRACKET = 91
    const val RBRACKET = 93
    const val COMMA = 44
    const val COLON = 58
    const val SEMI = 59
    const val BANG = 33
    const val QUESTION = 63
    const val LBRACE = 123
    const val RBRACE = 125
    const val PLUS = 43
    const val MINUS = 45
    const val STAR = 42
    const val CARET = 94
    const val AMP = 38
    const val PIPE = 124
    const val DOT = 46
    const val G = 103
    const val USHR_ASSIGN = 257
    const val AND_ASSIGN = 258
    const val OR_ASSIGN = 259
    const val NULL_ASSIGN = 260
    const val STRICT_EQUAL = 261
    const val STRICT_NOT_EQUAL = 262
    const val USHR = 263
    const val SHL_ASSIGN = 264
    const val SHR_ASSIGN = 265
    const val POW_ASSIGN = 266
    const val ARROW = 267
    const val EQ = 268
    const val NE = 269
    const val LE = 270
    const val GE = 271
    const val INC = 272
    const val DEC = 273
    const val AND = 274
    const val OR = 275
    const val NULLISH = 276
    const val SHL = 277
    const val SHR = 278
    const val PLUS_ASSIGN = 279
    const val MINUS_ASSIGN = 280
    const val STAR_ASSIGN = 281
    const val SLASH_ASSIGN = 282
    const val MOD_ASSIGN = 283
    const val AMP_ASSIGN = 284
    const val PIPE_ASSIGN = 285
    const val CARET_ASSIGN = 286
    const val POW = 287
    const val OPTIONAL = 288
    const val SPREAD = 289
    const val FUNCTION = 290
    const val IF = 291
    const val WHILE = 292
    const val FOR = 293
    const val SWITCH = 294
    const val CATCH = 295
    const val WITH = 296
    const val TYPEOF = 297
    const val VOID = 298
    const val DELETE = 299
    const val RETURN = 300
    const val THROW = 301
    const val NEW = 302
    const val VAR = 303
    const val LET = 304
    const val CONST = 305
    const val ELSE = 306
    const val CASE = 307
    const val TRUE = 308
    const val FALSE = 309
    const val NULL = 310
    const val UNDEFINED = 311
    const val NAN = 312
    const val INFINITY = 313
    const val SIGNATURETIMESTAMP = 314
    const val LENGTH = 315

    fun code(source: String, start: Int, end: Int): Int {
        val length = end - start
        if (length == 1) return source[start].code.takeIf { it < 128 } ?: IDENTIFIER
        return when (source[start]) {
            '!' -> when {
                length == 3 && source.regionMatches(start, "!==", 0, length) -> STRICT_NOT_EQUAL
                length == 2 && source.regionMatches(start, "!=", 0, length) -> NE
                else -> IDENTIFIER
            }
            '%' -> when {
                length == 2 && source.regionMatches(start, "%=", 0, length) -> MOD_ASSIGN
                else -> IDENTIFIER
            }
            '&' -> when {
                length == 3 && source.regionMatches(start, "&&=", 0, length) -> AND_ASSIGN
                length == 2 && source.regionMatches(start, "&&", 0, length) -> AND
                length == 2 && source.regionMatches(start, "&=", 0, length) -> AMP_ASSIGN
                else -> IDENTIFIER
            }
            '*' -> when {
                length == 3 && source.regionMatches(start, "**=", 0, length) -> POW_ASSIGN
                length == 2 && source.regionMatches(start, "*=", 0, length) -> STAR_ASSIGN
                length == 2 && source.regionMatches(start, "**", 0, length) -> POW
                else -> IDENTIFIER
            }
            '+' -> when {
                length == 2 && source.regionMatches(start, "++", 0, length) -> INC
                length == 2 && source.regionMatches(start, "+=", 0, length) -> PLUS_ASSIGN
                else -> IDENTIFIER
            }
            '-' -> when {
                length == 2 && source.regionMatches(start, "--", 0, length) -> DEC
                length == 2 && source.regionMatches(start, "-=", 0, length) -> MINUS_ASSIGN
                else -> IDENTIFIER
            }
            '.' -> when {
                length == 3 && source.regionMatches(start, "...", 0, length) -> SPREAD
                else -> IDENTIFIER
            }
            '/' -> when {
                length == 2 && source.regionMatches(start, "/=", 0, length) -> SLASH_ASSIGN
                else -> IDENTIFIER
            }
            '<' -> when {
                length == 3 && source.regionMatches(start, "<<=", 0, length) -> SHL_ASSIGN
                length == 2 && source.regionMatches(start, "<=", 0, length) -> LE
                length == 2 && source.regionMatches(start, "<<", 0, length) -> SHL
                else -> IDENTIFIER
            }
            '=' -> when {
                length == 3 && source.regionMatches(start, "===", 0, length) -> STRICT_EQUAL
                length == 2 && source.regionMatches(start, "=>", 0, length) -> ARROW
                length == 2 && source.regionMatches(start, "==", 0, length) -> EQ
                else -> IDENTIFIER
            }
            '>' -> when {
                length == 4 && source.regionMatches(start, ">>>=", 0, length) -> USHR_ASSIGN
                length == 3 && source.regionMatches(start, ">>>", 0, length) -> USHR
                length == 3 && source.regionMatches(start, ">>=", 0, length) -> SHR_ASSIGN
                length == 2 && source.regionMatches(start, ">=", 0, length) -> GE
                length == 2 && source.regionMatches(start, ">>", 0, length) -> SHR
                else -> IDENTIFIER
            }
            '?' -> when {
                length == 3 && source.regionMatches(start, "??=", 0, length) -> NULL_ASSIGN
                length == 2 && source.regionMatches(start, "??", 0, length) -> NULLISH
                length == 2 && source.regionMatches(start, "?.", 0, length) -> OPTIONAL
                else -> IDENTIFIER
            }
            'I' -> when {
                length == 8 && source.regionMatches(start, "Infinity", 0, length) -> INFINITY
                else -> IDENTIFIER
            }
            'N' -> when {
                length == 3 && source.regionMatches(start, "NaN", 0, length) -> NAN
                else -> IDENTIFIER
            }
            '^' -> when {
                length == 2 && source.regionMatches(start, "^=", 0, length) -> CARET_ASSIGN
                else -> IDENTIFIER
            }
            'c' -> when {
                length == 5 && source.regionMatches(start, "catch", 0, length) -> CATCH
                length == 5 && source.regionMatches(start, "const", 0, length) -> CONST
                length == 4 && source.regionMatches(start, "case", 0, length) -> CASE
                else -> IDENTIFIER
            }
            'd' -> when {
                length == 6 && source.regionMatches(start, "delete", 0, length) -> DELETE
                else -> IDENTIFIER
            }
            'e' -> when {
                length == 4 && source.regionMatches(start, "else", 0, length) -> ELSE
                else -> IDENTIFIER
            }
            'f' -> when {
                length == 8 && source.regionMatches(start, "function", 0, length) -> FUNCTION
                length == 3 && source.regionMatches(start, "for", 0, length) -> FOR
                length == 5 && source.regionMatches(start, "false", 0, length) -> FALSE
                else -> IDENTIFIER
            }
            'i' -> when {
                length == 2 && source.regionMatches(start, "if", 0, length) -> IF
                else -> IDENTIFIER
            }
            'l' -> when {
                length == 3 && source.regionMatches(start, "let", 0, length) -> LET
                length == 6 && source.regionMatches(start, "length", 0, length) -> LENGTH
                else -> IDENTIFIER
            }
            'n' -> when {
                length == 3 && source.regionMatches(start, "new", 0, length) -> NEW
                length == 4 && source.regionMatches(start, "null", 0, length) -> NULL
                else -> IDENTIFIER
            }
            'r' -> when {
                length == 6 && source.regionMatches(start, "return", 0, length) -> RETURN
                else -> IDENTIFIER
            }
            's' -> when {
                length == 6 && source.regionMatches(start, "switch", 0, length) -> SWITCH
                length == 18 && source.regionMatches(start, "signatureTimestamp", 0, length) -> SIGNATURETIMESTAMP
                else -> IDENTIFIER
            }
            't' -> when {
                length == 6 && source.regionMatches(start, "typeof", 0, length) -> TYPEOF
                length == 5 && source.regionMatches(start, "throw", 0, length) -> THROW
                length == 4 && source.regionMatches(start, "true", 0, length) -> TRUE
                else -> IDENTIFIER
            }
            'u' -> when {
                length == 9 && source.regionMatches(start, "undefined", 0, length) -> UNDEFINED
                else -> IDENTIFIER
            }
            'v' -> when {
                length == 4 && source.regionMatches(start, "void", 0, length) -> VOID
                length == 3 && source.regionMatches(start, "var", 0, length) -> VAR
                else -> IDENTIFIER
            }
            'w' -> when {
                length == 5 && source.regionMatches(start, "while", 0, length) -> WHILE
                length == 4 && source.regionMatches(start, "with", 0, length) -> WITH
                else -> IDENTIFIER
            }
            '|' -> when {
                length == 3 && source.regionMatches(start, "||=", 0, length) -> OR_ASSIGN
                length == 2 && source.regionMatches(start, "||", 0, length) -> OR
                length == 2 && source.regionMatches(start, "|=", 0, length) -> PIPE_ASSIGN
                else -> IDENTIFIER
            }
            else -> IDENTIFIER
        }
    }
}

/** The same 96-token lookbehind as the indexer, without transient Token objects. */
internal class ScanWindow(private val source: String) {
    private val starts = IntArray(96)
    private val ends = IntArray(96)
    private val kinds = IntArray(96)
    private val retained = arrayOfNulls<Token>(96)
    private var head = 0
    var size: Int = 0
        private set
    val lastIndex: Int get() = size - 1
    private fun slot(index: Int): Int = (head + index) % 96
    fun kind(index: Int): Int = kinds[slot(index)]
    private fun token(index: Int): Token {
        val i = slot(index)
        return retained[i] ?: Token(
            if (kinds[i] == 1) Lexer(source, starts[i]).next().text else source.substring(starts[i], ends[i]),
            kinds[i], starts[i],
        ).also { retained[i] = it }
    }
    fun text(index: Int): String = token(index).text
    fun isText(index: Int, value: String): Boolean {
        if (index !in 0 until size) return false
        val i = slot(index)
        return if (kinds[i] == 1) text(index) == value
        else ends[i] - starts[i] == value.length && source.regionMatches(starts[i], value, 0, value.length)
    }
    fun identifier(index: Int): Boolean {
        val i = slot(index)
        return kinds[i] == 0 && scanIdentifier(source, starts[i], ends[i])
    }
    fun retain(start: Int, end: Int): List<Token> = List(end - start) { token(start + it) }
    fun add(lexer: Lexer) {
        if (size == 96) head = (head + 1) % 96 else size++
        val i = slot(lastIndex)
        starts[i] = lexer.offset
        ends[i] = lexer.end
        kinds[i] = lexer.kind
        retained[i] = null
    }
}

internal fun scanIdentifier(source: String, start: Int, end: Int): Boolean {
    if (start == end) return false
    for (i in start until end) {
        val c = source[i]
        if (c !in 'A'..'Z' && c !in 'a'..'z' && c != '_' && c != '$' && !(i > start && c in '0'..'9')) return false
    }
    return true
}
