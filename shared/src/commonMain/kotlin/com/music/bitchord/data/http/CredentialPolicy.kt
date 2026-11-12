package com.music.bitchord.data.http

import io.ktor.http.Url

/** Scheme/host/port form a credential boundary, including on redirects. */
object CredentialPolicy {
    fun sameOrigin(first: String, second: String): Boolean = runCatching {
        val a = Url(first); val b = Url(second)
        a.protocol == b.protocol && a.host.equals(b.host, ignoreCase = true) && a.port == b.port
    }.getOrDefault(false)

    fun mayRedirect(from: String, to: String, carriesCredentials: Boolean): Boolean = runCatching {
        val a = Url(from); val b = Url(to)
        b.protocol.name in setOf("http", "https") && b.user.isNullOrEmpty() && b.password.isNullOrEmpty() &&
            !(a.protocol.name == "https" && b.protocol.name != "https") &&
            (!carriesCredentials || sameOrigin(from, to))
    }.getOrDefault(false)

    /**
     * Whether the persistent cookie jar may serve [host].
     *
     * Never for Google. YouTube answers anonymous requests with identity
     * cookies (`VISITOR_INFO1_LIVE`, `__Secure-YNID`), and a jar that keeps
     * them on disk sends the same visitor on every later request: a fresh
     * visitor id asked for after a bot check comes back as the flagged one, on
     * every network, across relaunches and accounts. The account session
     * travels as an explicit header and needs no jar.
     */
    fun jarServes(host: String?): Boolean {
        val name = host?.lowercase()?.trimEnd('.') ?: return true
        return GOOGLE_DOMAINS.none { name == it || name.endsWith(".$it") }
    }

    private val GOOGLE_DOMAINS = listOf(
        "youtube.com", "youtube-nocookie.com", "youtu.be", "google.com", "googlevideo.com",
        "googleapis.com", "googleusercontent.com", "ytimg.com", "ggpht.com", "gstatic.com",
    )
}
