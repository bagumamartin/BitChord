package com.music.bitchord.data.http

/**
 * One HTTP seam for the whole app (port of upstream `data/Http.kt` per spec
 * §1.2). The point of it being *one* seam is upstream's, and it is load-bearing:
 *
 *  > googlevideo binds a stream URL to the connection context of the `player`
 *  > request that minted it. If Innertube and the media fetch used separate
 *  > HTTP stacks they could resolve to different addresses (v4 vs v6) and the
 *  > media fetch would come back 403.
 *
 * So the Darwin actual runs one client on one `URLSession` and every caller —
 * innertube, the media fetch, the range probe, the lyrics and canvas providers
 * — goes through it.
 *
 * ## How the session cookie travels
 *
 * As a request **header**, exactly as upstream sends it (`Innertube.authHeaders`
 * puts `Cookie` in the header map and nothing writes it to a jar). That is the
 * whole mechanism, and it is the correct one:
 *
 *  - An `HTTPCookieStorage` is domain-scoped, so a session written to one for
 *    `.youtube.com` could never reach `*.googlevideo.com` anyway. Isolating
 *    the media client from the session was buying nothing.
 *  - The only way that isolation *could* have worked — mirroring the header
 *    into a jar — is a duplicate. A `URLSession` configured with
 *    `httpShouldSetCookies` sends the jar's cookies *and* the explicit header,
 *    so every signed-in request went out with two `Cookie` headers.
 *  - The jar version had to re-derive each cookie's domain by string surgery on
 *    the header, with a `__Host-` special case and no handling for the
 *    `__Secure-` forms Google actually sets, and it cleared the entire jar on
 *    every sign-in — taking unrelated provider cookies with it.
 *
 * [setHostCookies] below is the one place a jar is written, and it is for
 * cookies a *provider* needs on a later request to a host we already know
 * (Spotify's `sp_dc`). It is never used for the account session.
 */
expect object Http {
    /** Shared transport for maintained extraction and its media requests. */
    internal val client: io.ktor.client.HttpClient
    /** POST JSON, return the response body as text. */
    @Throws(Exception::class)
    suspend fun postJson(
        url: String,
        body: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): String

    /** GET, return the response body as text. */
    @Throws(Exception::class)
    suspend fun getText(
        url: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): String

    /**
     * GET, return the response body as raw bytes. Uses the same Ktor Darwin
     * engine as [probe], so it has the same TLS fingerprint that googlevideo
     * accepts. Range requests are supported via [headers].
     */
    @Throws(Exception::class)
    suspend fun getBytes(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 60_000,
    ): ByteArray

    /**
     * The answer to a ranged GET: status + content type, after a few bytes of
     * body have actually arrived. This is upstream's stream `probe` — the test
     * that tells a URL that serves audio from one that 403s on the first real
     * read, before it is handed to the engine.
     */
    @Throws(Exception::class)
    suspend fun probe(url: String, headers: Map<String, String> = emptyMap()): ProbeResult

    /**
     * GET that returns the status code and ignores the body. Stats pings
     * (`s.youtube.com`) answer 204; treating that as an error would drop plays.
     */
    @Throws(Exception::class)
    suspend fun getStatus(
        url: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 15_000,
    ): Int

    /**
     * POST application/x-www-form-urlencoded. Non-2xx still returns the body.
     */
    @Throws(Exception::class)
    suspend fun postForm(
        url: String,
        fields: Map<String, String>,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): String

    /**
     * GET that does not throw on non-2xx. Used by lyrics/canvas providers that
     * need the status code.
     */
    @Throws(Exception::class)
    suspend fun getRaw(
        url: String,
        headers: Map<String, String> = emptyMap(),
        query: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 8_000,
    ): RawHttpText

    /** POST raw bytes (protobuf / JSON without a forced charset). */
    @Throws(Exception::class)
    suspend fun postBytes(
        url: String,
        body: ByteArray,
        contentType: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 15_000,
    ): RawHttpBytes

    /**
     * One request with an arbitrary method, returning status and body.
     *
     * For the methods a protocol needs that are not GET or POST, and which therefore
     * have no business each growing their own seam here: WebDAV's `PROPFIND`,
     * `MKCOL` and `PUT`, and the party socket's handshake. Every one of them wants
     * exactly what [getRaw] already offers — the status, and the body whether or not
     * the status was a success — and the difference is one word.
     *
     * Non-2xx returns rather than throws, for the same reason as [getRaw]: a WebDAV
     * `412` and a `405` are *answers*, and reading them is the whole point.
     */
    @Throws(Exception::class)
    suspend fun requestRaw(
        url: String,
        method: String,
        body: String? = null,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 30_000,
    ): RawHttpText

    /**
     * The same, with a byte body, for a `PUT` of audio.
     *
     * Separate from [requestRaw] rather than a string overload because a hundred
     * megabyte FLAC has no encoding a string is the right answer for, and because the
     * caller's decision about how to stream it is not something this seam should
     * hide behind a `String`.
     */
    @Throws(Exception::class)
    suspend fun requestBytes(
        url: String,
        method: String,
        body: ByteArray,
        contentType: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMillis: Long = 120_000,
    ): RawHttpBytes

    /**
     * A GET that returns raw bytes and the status, reading **at most** [maxBytes] of
     * the body.
     *
     * [getBytes] cannot answer a ranged read, because the whole point of a ranged read
     * is the difference between a `206` and a `200` — the first is a server that
     * honoured the range, the second is one that ignored it and sent the entire file.
     * A caller finding a cover has to be able to tell those apart, and it has to be
     * able to do so *without* receiving the entire file to find out: a cover is a few
     * kilobytes at the front of a hundred-megabyte FLAC, so the bound is what keeps
     * "this server does not do ranges" from costing a whole download per track.
     *
     * Non-2xx returns rather than throws, for the same reason as [getRaw]: a `404` on
     * a cover is an answer.
     */
    @Throws(Exception::class)
    suspend fun getBytesRaw(
        url: String,
        headers: Map<String, String> = emptyMap(),
        maxBytes: Int = Int.MAX_VALUE,
        timeoutMillis: Long = 30_000,
    ): RawHttpBytes

    /**
     * Write cookies for [originUrl] into the jar so a subsequent [getRaw]
     * actually sends them. For a provider that handed us a cookie to reuse on
     * a later request to a host we already know — never for the account
     * session, which travels as a header (see the type-level note).
     *
     * Replaces any cookie of the same name for that host, so a rotated
     * credential does not leave the previous one behind to be sent first.
     */
    fun setHostCookies(originUrl: String, cookies: Map<String, String>)
}

data class RawHttpText(val status: Int, val body: String?)

data class RawHttpBytes(
    val status: Int, val body: ByteArray?, val contentType: String? = null,
    val contentRange: String? = null, val contentLength: Long? = null,
)

/** [Http.probe]'s verdict input; the classification happens where it is read. */
data class ProbeResult(
    val status: Int,
    val contentType: String?,
    /** Whether any body bytes arrived at all. */
    val bodyArrived: Boolean,
)

class HttpStatusException(val status: Int) : IllegalStateException("Request failed (HTTP $status)")
