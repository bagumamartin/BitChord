package com.music.bitchord.data.innertube

/**
 * The stream cipher's preprocessed players, kept across launches.
 *
 * When no remote player config covers YouTube's current player, the yt-dlp
 * solver derives a small "preprocessed player" from the full one: it parses
 * the whole multi-megabyte script with a JavaScript parser that itself runs in
 * the interpreter, about a second and a half of a core. The library keeps the
 * result in memory and offers a read/write hook for a disk tier, which this
 * app had never wired, so every launch (and every session refresh) paid that
 * parse again at the first track that needed deciphering, usually a track
 * change.
 *
 * Nothing about what is solved changes. Entries are keyed by the library on the
 * player URL and its solver bundle's digest, a hit is used only when it solves
 * every challenge of the request, and anything else is evicted and the full
 * player is solved exactly as before. A new YouTube player is a new key.
 */
internal expect object PreprocessedPlayerStore {
    fun read(key: String): String?

    /** Null removes the entry. */
    fun write(key: String, value: String?)
}
