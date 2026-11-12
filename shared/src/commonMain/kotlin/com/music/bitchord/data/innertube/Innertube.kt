package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.ProbeResult
import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.music.bitchord.data.model.LikeStatus
import com.music.bitchord.data.model.PlaylistPrivacy
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.JsonArrayBuilder
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import com.music.bitchord.data.http.HttpStatusException
import kotlin.time.Clock
import kotlinx.io.IOException

/**
 * Port of upstream `data/innertube/Innertube.kt` — the guest-browse subset
 * the Apple app consumes, plus everything playback and the account flow
 * need: the `player` endpoint walked across device clients, the `next`
 * endpoint that powers the AutoPlay radio, and the signed-in WEB_REMIX
 * session plumbing (cookie + SAPISIDHASH).
 *
 * Two kinds of client identity, for different reasons:
 *
 *  - **WEB_REMIX** against music.youtube.com for browse/search/library. It
 *    returns the full YT Music shelf layout and honours the signed-in session.
 *
 *  - **A device client** for the `player` endpoint, chosen per call. Which
 *    ones Google answers changes without notice, so [player] takes the
 *    identity as an argument and [PlayerBridge] walks a list of them rather
 *    than betting the app on any single one. See [PlayerClient].
 *
 * Authenticated requests are signed with Google's SAPISIDHASH scheme derived
 * from the stored cookie; no long-lived token is ever minted or stored.
 */
@OptIn(ExperimentalAtomicApi::class)
object Innertube {

    private const val MUSIC_BASE = "https://music.youtube.com/youtubei/v1"
    private const val YT_BASE = "https://www.youtube.com/youtubei/v1"
    private const val MUSIC_ORIGIN = "https://music.youtube.com"
    private const val YOUTUBE_ORIGIN = "https://www.youtube.com"

    /** Fallback WEB_REMIX version — [ensureSessionScope] replaces this with
     *  the live one from the signed-in music.youtube.com shell. */
    private const val WEB_REMIX_VERSION = "1.20250101.01.00"
    private const val WEB_REMIX_CLIENT_ID = "67"

    private const val WEB_USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private val json = Json { ignoreUnknownKeys = true }

    // One immutable state: request identity must never mix two account selections.
    private data class SessionState(
        val generation: Long = 0,
        val cookie: String? = null,
        val scope: SessionScope? = null,
        val channel: ChannelSelection? = null,
        val visitor: String? = null,
        val visitorBound: Boolean = false,
    )
    private val sessionState = AtomicReference(SessionState())
    private fun updateSession(change: (SessionState) -> SessionState) {
        while (true) {
            val before = sessionState.load()
            if (sessionState.compareAndSet(before, change(before))) return
        }
    }
    val sessionGeneration: Long get() = sessionState.load().generation
    var cookie: String?
        get() = sessionState.load().cookie
        set(value) {
            if (value == cookie) return
            updateSession { SessionState(generation = it.generation + 1, cookie = value) }
            sessionChanged()
        }
    private var visitorData: String?
        get() = sessionState.load().visitor
        set(value) { updateSession { it.copy(visitor = value) } }
    private val visitorDataIsSessionBound: Boolean get() = sessionState.load().visitorBound
    private val scope: SessionScope? get() = sessionState.load().scope
    private val channelOverride: ChannelSelection? get() = sessionState.load().channel

    private fun sessionChanged() {
        com.music.bitchord.data.LikeState.clear()
        StreamResolver.onSessionChanged()
        PlaybackTracker.onSessionChanged()
    }
    class SessionUnavailableException : IllegalStateException("Your saved session could not be verified. Try again when connected.")
    class AuthenticationException : IllegalStateException(SESSION_EXPIRED_MESSAGE)
    class PlayerAuthenticationException : IllegalStateException("This playback client rejected authentication")
    class SessionChangedException : CancellationException("Account changed during request")

    /**
     * The one text the store uses for "the session itself is gone", so the host
     * never keeps a hand-copied version of it — see [AuthBridge.isSessionExpired].
     */
    internal const val SESSION_EXPIRED_MESSAGE = "Your YouTube Music session has expired. Sign in again."

    internal class RequestSession(
        val generation: Long,
        val cookie: String?,
        val authUser: String?,
        val pageId: String?,
        val dataSyncId: String?,
        val visitor: String?,
        val clientVersion: String,
    )
    internal fun requestSession(): RequestSession {
        val state = sessionState.load()
        if (state.cookie != null && state.scope == null) throw SessionUnavailableException()
        val chosen = state.channel
        return RequestSession(state.generation, state.cookie,
            chosen?.authUser ?: state.scope?.authUser,
            if (chosen != null) chosen.pageId else state.scope?.pageId,
            if (chosen != null) chosen.dataSyncId else state.scope?.dataSyncId,
            state.visitor, state.scope?.clientVersion ?: WEB_REMIX_VERSION)
    }
    internal fun checkSession(generation: Long) {
        if (sessionGeneration != generation) throw SessionChangedException()
    }

    /**
     * A visitor id for this session, minting one if there isn't one yet.
     * [refresh] discards the current id — worth doing exactly once when a
     * request comes back accusing us of being a bot.
     */
    suspend fun ensureVisitorData(refresh: Boolean = false): String? {
        if (!refresh && visitorData != null) return visitorData
        val generation = sessionGeneration
        runCatching { fetchVisitorData() }
            .getOrNull()
            ?.let {
                updateSession { state ->
                    if (state.generation == generation && !state.visitorBound) state.copy(visitor = it)
                    else state
                }
            }
        return visitorData
    }

    /**
     * The service worker bootstrap the web player loads before anything else,
     * which is where a fresh visitor id comes from without needing a page. It
     * answers with an anti-hijacking prefix and then plain nested arrays, so
     * the id is found by shape rather than by a path that would rot.
     */
    /** A visitor id that belongs to no session: never stored here, never tied to the account. */
    internal suspend fun mintAnonymousVisitor(): String? = fetchVisitorData()

    private suspend fun fetchVisitorData(): String? {
        val body = Http.getText(
            "https://www.youtube.com/sw.js_data",
            headers = mapOf("User-Agent" to WEB_USER_AGENT),
        )
        val payload = json.parseToJsonElement(body.substringAfter("\n", body.drop(5)))
        return findVisitorData(payload)
    }

    private fun findVisitorData(element: JsonElement): String? = when (element) {
        is JsonArray -> element.firstNotNullOfOrNull { findVisitorData(it) }
        is JsonPrimitive -> element.contentOrNull?.takeIf { VISITOR_DATA.matches(it) }
        else -> null
    }

    /** Protobuf-in-base64; always this shape, and nothing else in there is. */
    private val VISITOR_DATA = Regex("""Cg[A-Za-z0-9_%-]{40,}""")

    // ---- Which account is this, exactly -------------------------------------

    /**
     * Who the session cookie actually acts as. A cookie is not an account:
     * one Google login carries every account the browser has signed into, and
     * nothing in the cookie says which one is meant. Guessing `X-Goog-AuthUser:
     * 0` credits history and library to the first account in the jar.
     *
     * [dataSyncId] is only ever taken from a shell that reported itself signed
     * in — Google answers an `onBehalfOfUser` it cannot tie to the cookie with
     * 401.
     */
    private class SessionScope(
        val dataSyncId: String?,
        val pageId: String?,
        val authUser: String,
        val clientVersion: String?,
    )

    private val scopeLock = Mutex()

    /**
     * The brand channel the listener chose to listen as, which outranks
     * whatever the session shell says.
     *
     * A Google account can own more than one YouTube identity, and the shell
     * can only ever report the one music.youtube.com serves by default. The
     * whole reason the in-app browser exists is that the listener has just said,
     * by hand, that they want a different one — so the answer is written down
     * here and every request uses it in place of the shell's.
     */
    class ChannelSelection(
        val pageId: String?,
        val dataSyncId: String?,
        /**
         * Which account in the cookie jar the channel belongs to. Null leaves
         * the shell's own answer alone: a brand channel sits under the account
         * that owns it, so this only differs when the listener switched to a
         * channel of a *different* signed-in Google account.
         */
        val authUser: String? = null,
    )

    /** Adopts a page scope read out of a page the listener was actually looking at. */
    fun adoptPageScope(pageId: String?, dataSyncId: String?, authUser: String?) {
        val chosen = if (pageId == null && dataSyncId == null && authUser == null) null
            else ChannelSelection(pageId, dataSyncId, authUser)
        val before = channelOverride
        if (before?.pageId == chosen?.pageId && before?.dataSyncId == chosen?.dataSyncId && before?.authUser == chosen?.authUser) return
        updateSession { it.copy(generation = it.generation + 1, channel = chosen) }
        sessionChanged()
    }

    /**
     * Takes the session scope from a page the listener was actually looking at,
     * rather than working it out later from a fetch of our own — port of upstream
     * `adoptSessionScope`.
     *
     * The shell fetch in [fetchSessionScope] can only ever report the channel
     * music.youtube.com serves by default, and the whole reason the in-app browser
     * exists is that the listener has just told it, by hand, that they want a
     * different one. That answer is written into the page's own `ytcfg`, so it is
     * read from there and adopted whole.
     *
     * Adopting also settles [ensureSessionScope] — a scope already in hand is not
     * refetched — so the shell cannot quietly overwrite the choice with its default
     * on the next request. A page that reported itself signed out is ignored apart
     * from its client version: its `DATASYNC_ID` belongs to no account, and sending
     * one Google cannot tie to the session is answered with 401 on every request.
     */
    fun adoptSessionScope(
        pageId: String?,
        dataSyncId: String?,
        authUser: String?,
        visitorData: String?,
        clientVersion: String?,
        loggedIn: Boolean,
    ) {
        updateSession { state ->
            val version = clientVersion?.takeIf { it.isNotBlank() } ?: state.scope?.clientVersion
            state.copy(generation = state.generation + 1,
                scope = if (loggedIn && !authUser.isNullOrBlank()) SessionScope(dataSyncId?.takeIf { it.isNotBlank() },
                    pageId?.takeIf { it.isNotBlank() }, authUser, version) else null,
                visitor = visitorData?.takeIf { it.isNotBlank() } ?: state.visitor,
                visitorBound = loggedIn && !visitorData.isNullOrBlank())
        }
        sessionChanged()
    }

    /**
     * Value accepted by Innertube as `context.user.onBehalfOfUser` — port of upstream
     * `normalizeDataSyncId`. YouTube commonly exposes `DATASYNC_ID` as
     * `account||delegated`; the second half is the active identity, while plain
     * accounts can leave it empty.
     */
    fun normalizeDataSyncId(raw: String?): String? {
        val value = raw?.takeIf { it.isNotBlank() } ?: return null
        if (!value.contains("||")) return value
        return value.substringAfter("||").takeIf { it.isNotBlank() }
            ?: value.substringBefore("||").takeIf { it.isNotBlank() }
    }

    /**
     * The identity the session is currently acting as, or null when there is no
     * session at all.
     *
     * Which channel that is *depends on the override* — the same [pageIdFor] /
     * [dataSyncIdFor] / [authUserFor] the requests themselves use, so a caller
     * asking "who am I" cannot be told a different answer from the one the next
     * request will send. That is the whole reason this is a function and not the
     * raw scope: reading the scope directly would report the shell's default
     * identity after a listener had switched to another one.
     *
     * Null `pageId` and `dataSyncId` together mean the session has not settled on
     * an identity yet, and a caller must treat that as "unknown" rather than as
     * an identity with empty fields.
     */
    fun currentIdentity(): ChannelSelection? {
        val session = scope ?: return null
        val pageId = pageIdFor(session)
        val dataSyncId = dataSyncIdFor(session)
        if (pageId == null && dataSyncId == null) return null
        return ChannelSelection(pageId, dataSyncId, authUserFor(session))
    }

    /**
     * The brand channel to send, chosen one first.
     *
     * The shape is `override ?: shell` rather than "override, else shell" as a
     * fallback chain, and the difference matters: once a channel has been chosen
     * there is no falling back to the shell's value at all, because the shell's
     * id names the *default* identity and pairing it with another channel's
     * [ChannelSelection.pageId] describes an account/page combination that does
     * not exist. A half-overridden identity is worse than an unsigned request.
     */
    private fun pageIdFor(session: SessionScope?): String? =
        channelOverride.let { if (it != null) it.pageId else session?.pageId }

    /** The account to send as `onBehalfOfUser`. No fallback, for the reason above. */
    private fun dataSyncIdFor(session: SessionScope?): String? =
        channelOverride.let { if (it != null) it.dataSyncId else session?.dataSyncId }

    /**
     * Which account in the cookie jar, chosen channel's first.
     *
     * This one *does* fall back: [ChannelSelection.authUser] is null for a
     * channel belonging to the account that is already signed in, and there is
     * nothing contradictory about the shell's answer in that case.
     */
    private fun authUserFor(session: SessionScope?): String =
        channelOverride?.authUser ?: session?.authUser ?: "0"

    private val webRemixVersion: String
        get() = scope?.clientVersion ?: WEB_REMIX_VERSION

    /** Resolve signed-in identity before issuing any account-bound request. */
    suspend fun ensureSessionScope() {
        val expected = sessionState.load()
        val session = expected.cookie ?: return
        if (expected.scope != null) return
        scopeLock.withLock {
            checkSession(expected.generation)
            if (scope != null) return
            val fresh = try { fetchSessionScope(session, expected.generation) }
            catch (error: CancellationException) { throw error }
            catch (error: AuthenticationException) { throw error }
            catch (error: HttpStatusException) {
                if (error.status == 401) throw AuthenticationException()
                throw SessionUnavailableException()
            }
            catch (error: Throwable) { throw SessionUnavailableException() }
            checkSession(expected.generation)
            updateSession { state ->
                if (state.generation == expected.generation) state.copy(scope = fresh) else state
            }
            checkSession(expected.generation)
        }
    }

    /**
     * The music.youtube.com shell, for its `ytcfg`. Read by regex rather than
     * evaluating the config blob. A key that moves reads as absent.
     */
    internal var scopeTransport: suspend (String) -> String = { session ->
        Http.getText(
            "$MUSIC_ORIGIN/",
            headers = buildMap {
                put("User-Agent", WEB_USER_AGENT)
                put("Accept-Language", "en-US,en;q=0.9")
                put("Cookie", session)
                sapisidFrom(session)?.let { put("Authorization", sapisidHash(it)) }
            },
        )
    }

    private suspend fun fetchSessionScope(session: String, generation: Long): SessionScope {
        val html = scopeTransport(session)
        val signedIn = CONFIG_LOGGED_IN.find(html)?.groupValues?.get(1) == "true"
        val clientVersion = CONFIG_CLIENT_VERSION.find(html)?.groupValues?.get(1)
        if (!signedIn) {
            throw AuthenticationException()
        }
        val dataSyncId = CONFIG_DATASYNC_ID.find(html)?.groupValues?.get(1)
            ?.let { normalizeDataSyncId(it) }
        val pageId = CONFIG_PAGE_ID.find(html)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
        val authUser = CONFIG_SESSION_INDEX.find(html)?.groupValues?.get(1)?.takeIf { it.isNotBlank() }
        CONFIG_VISITOR_DATA.find(html)?.groupValues?.get(1)
            ?.takeIf { it.isNotBlank() }
            ?.let {
                updateSession { state ->
                    if (state.generation == generation) state.copy(visitor = it, visitorBound = true) else state
                }
            }
        return SessionScope(dataSyncId, pageId, authUser ?: channelOverride?.authUser ?: throw SessionUnavailableException(), clientVersion)
    }

    private val CONFIG_LOGGED_IN = Regex(""""LOGGED_IN"\s*:\s*(true|false)""")
    private val CONFIG_DATASYNC_ID = Regex(""""DATASYNC_ID"\s*:\s*"([^"]+)"""")
    private val CONFIG_PAGE_ID = Regex(""""DELEGATED_SESSION_ID"\s*:\s*"([^"]+)"""")
    private val CONFIG_SESSION_INDEX = Regex(""""SESSION_INDEX"\s*:\s*"?(\d+)""")
    private val CONFIG_VISITOR_DATA = Regex(""""VISITOR_DATA"\s*:\s*"([^"]+)"""")
    private val CONFIG_CLIENT_VERSION = Regex(""""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"""")

    // ---- Public API ---------------------------------------------------------

    /**
     * Search YouTube Music. [params] is a filter chip's serialized params
     * (`SearchFilter` in the shared model); null = the "All" tab.
     */
    /**
     * The timed transcript YouTube holds for [videoId].
     *
     * `get_transcript` expects a tiny protobuf rather than JSON, and the field is
     * field 1, length-delimited: one tag byte, the id's length, then the id. The
     * id is always 11 characters, so the length never needs a varint — which is
     * what makes this hand-rolled encoding safe rather than merely convenient.
     */
    @OptIn(ExperimentalEncodingApi::class)
    suspend fun transcript(videoId: String): JsonObject = postMusic("get_transcript") {
        val id = videoId.encodeToByteArray()
        val bytes = ByteArray(2 + id.size)
        bytes[0] = 10 // field 1, wire type 2
        bytes[1] = id.size.toByte()
        id.copyInto(bytes, destinationOffset = 2)
        put("params", Base64.Default.encode(bytes))
    }

    suspend fun search(query: String, params: String? = null): JsonObject =
        postMusic("search") {
            put("query", query)
            params?.let { put("params", it) }
        }

    /**
     * The next page of a search result set — the same shape as the first page,
     * so [InnertubeParser.parseSearchPage] reads it unmodified. Mirrors
     * [browseContinuation]; upstream `Innertube.kt:626` `searchContinuation`.
     */
    suspend fun searchContinuation(token: String): JsonObject = postMusic(
        endpoint = "search",
        query = mapOf("ctoken" to token, "continuation" to token, "type" to "next"),
    ) {
        put("continuation", token)
    }

    /** Typeahead queries for a half-typed input — queries, not results. */
    suspend fun searchSuggestions(input: String): JsonObject =
        postMusic("music/get_search_suggestions") {
            put("input", input)
        }

    /**
     * Live media results for the typeahead phase — the same shape as [search]
     * but deliberately unauthenticated, so YouTube Music does not log each
     * debounced keystroke to the account's server-side search history. Upstream
     * `Innertube.kt:658` `searchTypeahead`.
     */
    suspend fun searchTypeahead(query: String): JsonObject = postMusic(
        endpoint = "search",
        anonymous = true,
    ) {
        put("query", query)
    }

    /**
     * A browse page — Home (`FEmusic_home`), Explore (`FEmusic_explore`),
     * charts (`FEmusic_charts`), new releases (`FEmusic_new_releases`) and
     * detail pages are all this one endpoint with a different id, upstream's
     * `browse` verbatim. Works as a guest.
     */
    suspend fun browse(browseId: String, params: String? = null): JsonObject =
        postMusic("browse", requireIdentity = browseId in PERSONAL_BROWSE) {
            put("browseId", browseId)
            params?.let { put("params", it) }
        }

    /**
     * The next page of a paged browse response — playlists come back roughly
     * 100 rows at a time. The token is sent in the body and as query
     * parameters; both forms are honoured.
     */
    suspend fun browseContinuation(token: String): JsonObject = postMusic(
        endpoint = "browse",
        query = mapOf("ctoken" to token, "continuation" to token, "type" to "next"),
    ) {
        put("continuation", token)
    }

    /** Signed-in profile: display name, email/handle and avatar. */
    suspend fun accountMenu(): JsonObject = postMusic("account/account_menu", requireIdentity = true) {}

    /**
     * The watch queue that YouTube Music would play after [videoId] — the
     * "RDAMVM" radio mix. Used to keep AutoPlay going past the last track.
     */
    suspend fun next(videoId: String): JsonObject = postMusic("next") {
        put("videoId", videoId)
        put("playlistId", "RDAMVM$videoId")
        put("isAudioOnly", true)
    }

    /**
     * The `player` response for [videoId] as seen by [client] — the audio
     * formats and whatever it takes to unlock them.
     *
     * @param signatureTimestamp sts from base.js; required when
     *   [PlayerClient.needsSignatureTimestamp] is true.
     * @param authenticated whether to carry the session cookie. Unauthenticated
     *   by default, which is right for the device clients — they are answered
     *   *because* they look like anonymous devices. It is the deliberate
     *   exception for [PlayerClient.WEB_REMIX], a browser identity that is
     *   suspicious without a session rather than with one, and for a device
     *   client that has just answered an age gate, where the anonymous request
     *   has already been refused so there is nothing left to protect. See
     *   [postPlayer] and [StreamResolver].
     * @throws UnplayableException when the track is refused rather than
     *   missing — a region block, a takedown, or the client being turned
     *   away. Callers walk on to the next client on that distinction.
     */
    suspend fun player(
        videoId: String,
        client: PlayerClient,
        signatureTimestamp: Int? = null,
        authenticated: Boolean = false,
    ): JsonObject {
        val response = postPlayer(videoId, client, signatureTimestamp, authenticated)
        val playability = response["playabilityStatus"] as? JsonObject
        val status = (playability?.get("status") as? JsonPrimitive)?.contentOrNull
        if (status != null && status != "OK") {
            throw UnplayableException(playabilityReason(playability) ?: status)
        }
        return response
    }

    /**
     * Prefer the human-readable refusal: `reason`, then nested `messages` /
     * errorScreen `subreason` (TVHTML5 often says "Video unavailable" with
     * subreason "The page needs to be reloaded").
     */
    private fun playabilityReason(playability: JsonObject?): String? {
        if (playability == null) return null
        val reason = (playability["reason"] as? JsonPrimitive)?.contentOrNull
        val sub = playability.subreason()
        return when {
            !sub.isNullOrBlank() && !reason.isNullOrBlank() &&
                !reason.contains(sub, ignoreCase = true) -> "$reason — $sub"
            !sub.isNullOrBlank() -> sub
            else -> reason
        }
    }

    private fun JsonObject.subreason(): String? {
        (get("messages") as? JsonArray)
            ?.filterIsInstance<JsonPrimitive>()
            ?.firstNotNullOfOrNull { it.contentOrNull }
            ?.let { return it }
        val errorScreen = get("errorScreen") as? JsonObject ?: return null
        fun dig(obj: JsonObject): String? {
            (obj["subreason"] as? JsonObject)?.let { sub ->
                (sub["simpleText"] as? JsonPrimitive)?.contentOrNull?.let { return it }
                (sub["runs"] as? JsonArray)
                    ?.filterIsInstance<JsonObject>()
                    ?.mapNotNull { (it["text"] as? JsonPrimitive)?.contentOrNull }
                    ?.joinToString("")
                    ?.takeIf { it.isNotBlank() }
                    ?.let { return it }
            }
            obj.values.forEach { v ->
                if (v is JsonObject) dig(v)?.let { return it }
            }
            return null
        }
        return dig(errorScreen)
    }

    class UnplayableException(private val reason: String) :
        IllegalStateException("Track unavailable: $reason") {

        /**
         * Whether this is Google doubting the client rather than the track
         * being unavailable. [isAgeGate] is excluded on purpose: YouTube
         * words its age gate "Sign in to confirm your age", which contains
         * "sign in" — an age gate is a verdict about one track and one
         * identity; a bot check is a verdict about the session.
         */
        val looksLikeBotCheck: Boolean
            get() = !isAgeGate && (
                reason.contains("bot", ignoreCase = true) ||
                    reason.contains("unusual traffic", ignoreCase = true) ||
                    reason.contains("sign in", ignoreCase = true) ||
                    reason.contains("login_required", ignoreCase = true) ||
                    // TVHTML5 on flagged networks — same session refusal, no
                    // "bot"/"sign in" wording (upstream StreamResolver notes).
                    reason.contains("page needs to be reloaded", ignoreCase = true)
                )

        val isAgeGate: Boolean
            get() = reason.contains("confirm your age", ignoreCase = true) ||
                reason.contains("age-restricted", ignoreCase = true) ||
                reason.contains("age restricted", ignoreCase = true) ||
                reason.contains("inappropriate for some users", ignoreCase = true)

        /**
         * Whether asking again can only ever get the same answer — a
         * takedown, a region block, a private or paid video. Deliberately
         * short; every entry a phrase Google uses for one verdict only.
         */
        val isPermanent: Boolean
            get() = PERMANENT_REASONS.any { reason.contains(it, ignoreCase = true) }

        val displayReason: String get() = reason

        private companion object {
            private val PERMANENT_REASONS = listOf(
                "not available in your country",
                "who has blocked it in your country",
                "removed by the uploader",
                "account associated with this video has been terminated",
                "private video",
                "members-only",
            )
        }
    }

    // ---- Play registration (account history / recommendations) --------------

    class PlaybackTracking(
        val playbackUrl: String,
        val watchtimeUrl: String?,
        val atrUrl: String?,
        val atrAfterSeconds: Long,
    )

    /**
     * WEB_REMIX `player` *with* the session, purely to read `playbackTracking`.
     * Device-client [player] skips auth so it never sees this block.
     */
    suspend fun playbackTracking(videoId: String, signatureTimestamp: Int?): PlaybackTracking? {
        if (cookie == null) return null
        ensureSessionScope()
        val response = postMusic("player") {
            put("videoId", videoId)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            putJsonObject("playbackContext") {
                putJsonObject("contentPlaybackContext") {
                    put("html5Preference", "HTML5_PREF_WANTS")
                    put("referer", "$MUSIC_ORIGIN/watch?v=$videoId")
                    signatureTimestamp?.let { put("signatureTimestamp", it) }
                }
            }
        }
        val tracking = response["playbackTracking"] as? JsonObject ?: return null
        val playbackUrl = tracking.trackingUrl("videostatsPlaybackUrl") ?: return null
        return PlaybackTracking(
            playbackUrl = playbackUrl,
            watchtimeUrl = tracking.trackingUrl("videostatsWatchtimeUrl"),
            atrUrl = tracking.trackingUrl("atrUrl"),
            atrAfterSeconds = ((tracking["atrUrl"] as? JsonObject)
                ?.get("elapsedMediaTimeSeconds") as? JsonPrimitive)
                ?.contentOrNull?.toLongOrNull() ?: 5L,
        )
    }

    private fun JsonObject.trackingUrl(key: String): String? =
        ((this[key] as? JsonObject)?.get("baseUrl") as? JsonPrimitive)?.contentOrNull

    suspend fun pingPlayback(baseUrl: String, cpn: String, generation: Long = sessionGeneration): Int =
        pingStats(baseUrl, cpn, generation = generation)

    suspend fun pingWatchtime(baseUrl: String, cpn: String, seconds: Long, final: Boolean = false, generation: Long = sessionGeneration): Int =
        pingStats(
            baseUrl,
            cpn,
            generation = generation,
            extra = buildMap {
                put("st", "0")
                put("et", seconds.toString())
                put("cmt", seconds.toString())
                put("state", if (final) "paused" else "playing")
                if (final) put("final", "1")
            },
        )

    suspend fun pingAtr(baseUrl: String, cpn: String, generation: Long = sessionGeneration): Int {
        val headers = statsHeaders(baseUrl, generation)
        return Http.getStatus(
            url = baseUrl,
            headers = headers,
            query = mapOf("cpn" to cpn),
        ).also { checkSession(generation) }
    }

    private suspend fun pingStats(
        baseUrl: String,
        cpn: String,
        extra: Map<String, String> = emptyMap(),
        generation: Long = sessionGeneration,
    ): Int {
        checkSession(generation)
        val session = requestSession()
        val headers = statsHeaders(baseUrl, generation, session)
        return Http.getStatus(
        url = baseUrl,
        headers = headers,
        query = mapOf(
            "ver" to "2",
            "c" to "WEB_REMIX",
            "cver" to session.clientVersion,
            "cpn" to cpn,
            "cplayer" to "UNIPLAYER",
            "cbr" to "Chrome",
            "cbrver" to "141.0.0.0",
            "cos" to "Windows",
            "cosver" to "10.0",
            "hl" to "en_US",
            "cr" to "US",
        ) + extra,
    ).also { checkSession(generation) }
    }

    private fun statsHeaders(url: String, generation: Long, session: RequestSession = requestSession()): Map<String, String> = buildMap {
        checkSession(generation)
        val target = io.ktor.http.Url(url)
        require(target.protocol.name == "https" && target.port == 443 && target.user.isNullOrEmpty() && target.password.isNullOrEmpty() && target.host in setOf("music.youtube.com", "www.youtube.com", "s.youtube.com")) { "Untrusted playback tracking destination" }
        checkSession(session.generation)
        put("X-Origin", MUSIC_ORIGIN)
        put("Origin", MUSIC_ORIGIN)
        put("Referer", "$MUSIC_ORIGIN/")
        put("User-Agent", WEB_USER_AGENT)
        session.visitor?.let { put("X-Goog-Visitor-Id", it) }
        putAll(authHeaders(session, MUSIC_ORIGIN))
    }

    fun newCpn(): String {
        val alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        return CharArray(16) { alphabet.random() }.concatToString()
    }

    // ---- Writes -------------------------------------------------------------

    class NotSignedInException : IllegalStateException("Sign in to YouTube Music to do that")

    private fun requireSession() {
        if (cookie == null) throw NotSignedInException()
    }

    suspend fun rate(videoId: String, status: LikeStatus) {
        requireSession()
        val endpoint = when (status) {
            LikeStatus.LIKE -> "like/like"
            LikeStatus.DISLIKE -> "like/dislike"
            LikeStatus.INDIFFERENT -> "like/removelike"
        }
        val response = postMusic(endpoint) {
            putJsonObject("target") { put("videoId", videoId) }
        }
        response["error"]?.let { error ->
            val message = error.jsonObject["message"]?.jsonPrimitive?.contentOrNull
            error("YouTube Music refused the rating: ${message ?: error}")
        }
    }

    suspend fun ratePlaylist(playlistId: String, saved: Boolean) {
        requireSession()
        val endpoint = if (saved) "like/like" else "like/removelike"
        val response = postMusic(endpoint) {
            putJsonObject("target") { put("playlistId", playlistId) }
        }
        response["error"]?.let { error ->
            val message = error.jsonObject["message"]?.jsonPrimitive?.contentOrNull
            error("YouTube Music refused the change: ${message ?: error}")
        }
    }

    /** Follow or unfollow a YouTube channel by the id supplied on its artist page. */
    suspend fun setSubscribed(channelId: String, subscribed: Boolean) {
        requireSession()
        val endpoint = if (subscribed) "subscription/subscribe" else "subscription/unsubscribe"
        val response = postMusic(endpoint) {
            putJsonArray("channelIds") { add(channelId) }
        }
        response["error"]?.let { error ->
            val message = error.jsonObject["message"]?.jsonPrimitive?.contentOrNull
            error("YouTube Music refused the subscription change: ${message ?: error}")
        }
    }

    suspend fun sendFeedback(token: String) {
        requireSession()
        postMusic("feedback") {
            putJsonArray("feedbackTokens") { add(token) }
        }
    }

    suspend fun createPlaylist(
        title: String,
        privacy: PlaylistPrivacy,
        description: String? = null,
        videoIds: List<String> = emptyList(),
    ): String {
        requireSession()
        val response = postMusic("playlist/create") {
            put("title", title)
            put("description", description.orEmpty())
            put("privacyStatus", privacy.apiValue)
            if (videoIds.isNotEmpty()) {
                putJsonArray("videoIds") { videoIds.forEach { add(it) } }
            }
        }
        return response["playlistId"]?.jsonPrimitive?.contentOrNull
            ?: findString(response, "playlistId")
            ?: error("playlist created but no id came back")
    }

    suspend fun deletePlaylist(playlistId: String) {
        requireSession()
        postMusic("playlist/delete") { put("playlistId", playlistId.removePrefix("VL")) }
    }

    private suspend fun editPlaylist(
        playlistId: String,
        actions: JsonArrayBuilder.() -> Unit,
    ): JsonObject {
        requireSession()
        val response = postMusic("browse/edit_playlist") {
            put("playlistId", playlistId.removePrefix("VL"))
            putJsonArray("actions", actions)
        }
        val status = response["status"]?.jsonPrimitive?.contentOrNull
        if (status != null && status != "STATUS_SUCCEEDED") {
            error("YouTube Music refused the edit ($status)")
        }
        return response
    }

    suspend fun addToPlaylist(playlistId: String, videoIds: List<String>): Map<String, String> {
        val response = editPlaylist(playlistId) {
            videoIds.forEach { videoId ->
                addJsonObject {
                    put("action", "ACTION_ADD_VIDEO")
                    put("addedVideoId", videoId)
                }
            }
        }
        return (response["playlistEditResults"] as? JsonArray)
            .orEmpty()
            .mapNotNull { result ->
                val added = (result as? JsonObject)
                    ?.get("playlistEditVideoAddedResultData") as? JsonObject
                    ?: return@mapNotNull null
                val videoId = (added["videoId"] as? JsonPrimitive)?.contentOrNull
                    ?: return@mapNotNull null
                val setVideoId = (added["setVideoId"] as? JsonPrimitive)?.contentOrNull
                    ?: return@mapNotNull null
                videoId to setVideoId
            }
            .toMap()
    }

    suspend fun removeFromPlaylist(playlistId: String, entries: List<Pair<String, String>>) {
        editPlaylist(playlistId) {
            entries.forEach { (setVideoId, videoId) ->
                addJsonObject {
                    put("action", "ACTION_REMOVE_VIDEO")
                    put("setVideoId", setVideoId)
                    put("removedVideoId", videoId)
                }
            }
        }
    }

    suspend fun renamePlaylist(playlistId: String, title: String) {
        editPlaylist(playlistId) {
            addJsonObject {
                put("action", "ACTION_SET_PLAYLIST_NAME")
                put("playlistName", title)
            }
        }
    }

    suspend fun setPlaylistPrivacy(playlistId: String, privacy: String) {
        val p = PlaylistPrivacy.entries.firstOrNull { it.name.equals(privacy, true) }
            ?: PlaylistPrivacy.PRIVATE
        editPlaylist(playlistId) {
            addJsonObject {
                put("action", "ACTION_SET_PLAYLIST_PRIVACY")
                put("playlistPrivacyStatus", p.apiValue)
            }
        }
    }

    /** Moves [setVideoId] to sit immediately before [successorSetVideoId], or last if null. */
    suspend fun movePlaylistItem(
        playlistId: String,
        setVideoId: String,
        successorSetVideoId: String?,
    ) {
        editPlaylist(playlistId) {
            addJsonObject {
                put("action", "ACTION_MOVE_VIDEO_AFTER")
                put("setVideoId", setVideoId)
                if (!successorSetVideoId.isNullOrBlank()) {
                    put("movedSetVideoIdSuccessor", successorSetVideoId)
                }
            }
        }
    }

    /** First string value under [key] anywhere in [element], depth-first. */
    private fun findString(element: JsonElement, key: String): String? = when (element) {
        is JsonObject -> (element[key] as? JsonPrimitive)?.contentOrNull
            ?: element.values.firstNotNullOfOrNull { findString(it, key) }
        is JsonArray -> element.firstNotNullOfOrNull { findString(it, key) }
        else -> null
    }

    // ---- Request plumbing ---------------------------------------------------

    /**
     * Runs [block], giving a transport failure another go before letting it
     * reach the caller.
     *
     * A connection reset on mobile data is weather, not information: the request
     * was fine and asking again generally answers. It matters more than usual
     * here, because everything goes through one client — which is the point of
     * [Http] and also what makes a socket torn down under one request surface
     * as an error on whichever request picks that connection up next, having
     * nothing to do with it. Without this, one stale socket reads as a refused
     * client, which then costs a whole extra identity on the walk, which is the
     * churn that gets the network throttled.
     *
     * Only transport failures. An HTTP error status is an *answer*, and
     * repeating the question will not change it. A timeout is not weather
     * either — it is this app's own decision that the request had long enough —
     * and because a timeout is also a transport failure, retrying one silently
     * multiplied a 6-second `player` ceiling into 18 and turned a walk of seven
     * clients into a walk of well over a minute. Cancellation is never caught:
     * a resolve whose caller has walked away must stop, not retry on behalf of
     * nobody.
     */
    private suspend fun <T> withRetry(what: String, attempts: Int = 3, block: suspend () -> T): T {
        var backoff = 500L
        repeat(attempts - 1) {
            try {
                return block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!e.isTransport()) throw e
                DebugLog.d("retrying $what after transport failure")
            }
            delay(backoff)
            backoff *= 2
        }
        return block()
    }

    /**
     * Whether [this] is a failure of the connection rather than of the request.
     *
     * The distinction cannot be read off the exception hierarchy across engines,
     * so it is read off what the failures have in common: the request never
     * completed, so there is nothing to be an answer *about*. A refused status
     * is an answer and must not be repeated; a body that failed to parse, or a
     * contract this app got wrong, will not parse or conform the second time
     * either and is worth surfacing.
     */
    private fun Throwable.isTransport(): Boolean {
        if (this is HttpRequestTimeoutException) return false
        var current: Throwable? = this
        val seen = HashSet<Throwable>()
        while (current != null && seen.add(current)) {
            if (current is HttpRequestTimeoutException) return false
            if (current is UnplayableException || current is NotSignedInException) return false
            if (current is IOException) return true
            val text = current.message?.lowercase().orEmpty()
            if (TRANSPORT_MARKERS.any { it in text }) return true
            current = current.cause
        }
        return false
    }

    /**
     * Wording the Darwin engine uses for a connection that failed before a
     * response, which it reports as an `NSError` rather than as an
     * `IOException` the way the JVM engine does.
     */
    private val TRANSPORT_MARKERS = listOf(
        "connection reset", "connection lost", "software caused connection abort",
        "connection refused", "network connection lost", "timed out", "broken pipe",
        "nodata", "cannot connect to host", "the network connection was lost",
        "unsatisfiable constraints", "could not connect",
    )

    internal class MusicRequest(val url: String, val body: String, val headers: Map<String, String>, val query: Map<String, String>)
    internal var musicTransport: suspend (MusicRequest) -> String = { request ->
        Http.postJson(request.url, request.body, request.headers, request.query)
    }

    internal var playerTransport: suspend (MusicRequest) -> String = { request ->
        Http.postJson(request.url, request.body, request.headers, request.query, timeoutMillis = PLAYER_TIMEOUT_MS)
    }

    private val PERSONAL_BROWSE = setOf("FEmusic_history", "FEmusic_liked_videos", "FEmusic_liked_playlists",
        "FEmusic_liked_albums", "FEmusic_library_corpus_track_artists", "FEmusic_library_corpus_artists", "FEmusic_library_non_music_audio_list")

    private val SAFE_MUSIC_READS = setOf("browse", "search", "music/get_search_suggestions", "account/account_menu", "next", "player", "get_transcript")

    private suspend fun postMusic(
        endpoint: String,
        query: Map<String, String> = emptyMap(),
        refreshAllowed: Boolean = true,
        requireIdentity: Boolean = false,
        anonymous: Boolean = false,
        bodyExtras: JsonObjectBuilder.() -> Unit,
    ): JsonObject {
        val generation = sessionGeneration
        ensureSessionScope()
        checkSession(generation)
        val session = requestSession()
        val clientVersion = session.clientVersion
        val safeRead = endpoint in SAFE_MUSIC_READS
        if ((!safeRead || requireIdentity) && session.cookie == null) throw NotSignedInException()
        val body = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", "WEB_REMIX")
                    put("clientVersion", clientVersion)
                    put("hl", "en")
                    put("gl", "US")
                    session.visitor?.let { put("visitorData", it) }
                }
                putJsonObject("user") {
                    put("lockedSafetyMode", false)
                    // No account context on an anonymous read: sending a
                    // session's dataSyncId without the cookie that goes with it
                    // is a malformed signed-in request, and the server answers
                    // it with nothing. Upstream's postMusicAnonymous omits it too.
                    if (!anonymous) session.dataSyncId?.let { put("onBehalfOfUser", it) }
                }
                putJsonObject("request") { put("useSsl", true) }
            }
            bodyExtras()
        }
        val headers = buildMap {
            put("User-Agent", WEB_USER_AGENT)
            put("X-Origin", MUSIC_ORIGIN)
            put("Origin", MUSIC_ORIGIN)
            put("Referer", "$MUSIC_ORIGIN/")
            put("X-YouTube-Client-Name", WEB_REMIX_CLIENT_ID)
            put("X-YouTube-Client-Version", clientVersion)
            session.visitor?.let { put("X-Goog-Visitor-Id", it) }
            if (!anonymous) putAll(authHeaders(session, MUSIC_ORIGIN))
        }
        val text = try { withRetry("postMusic/$endpoint", attempts = if (safeRead) 3 else 1) {
            checkSession(generation)
            musicTransport(MusicRequest("$MUSIC_BASE/$endpoint",
                json.encodeToString(JsonObject.serializer(), body), headers,
                query + ("prettyPrint" to "false")))
        }
        } catch (error: HttpStatusException) {
            if (error.status == 401 && session.cookie != null) {
                if (safeRead && refreshAllowed) {
                    checkSession(generation)
                    updateSession { if (it.generation == generation) it.copy(scope = null) else it }
                    return postMusic(endpoint, query, refreshAllowed = false, requireIdentity = requireIdentity, anonymous = anonymous, bodyExtras = bodyExtras)
                }
                throw AuthenticationException()
            }
            throw error
        }
        checkSession(generation)
        val response = json.parseToJsonElement(text) as? JsonObject
            ?: error("innertube $endpoint: unexpected response shape")
        // Browse responses carry one; a session that never happened to see
        // one would silently never play anything.
            if (visitorData == null && !visitorDataIsSessionBound) {
                visitorData = ((response["responseContext"] as? JsonObject)
                    ?.get("visitorData") as? JsonPrimitive)?.contentOrNull
            }
        return response
    }

    /**
     * Unauthenticated by default — the device clients are answered *because*
     * they look like anonymous devices; attaching a session cookie to one of
     * those is what gets it turned away with `LOGIN_REQUIRED`.
     *
     * [authenticated] is the deliberate exception, and it is the whole reason a
     * signed-in listener is not treated as a stranger. There are two callers:
     * [PlayerClient.WEB_REMIX], a browser identity that reads as suspicious
     * *without* a session; and a device client that has just answered an age
     * gate, which the same client will answer OK for once it carries the
     * cookie. See [StreamResolver].
     */
    private suspend fun postPlayer(
        videoId: String,
        playerClient: PlayerClient,
        signatureTimestamp: Int? = null,
        authenticated: Boolean = false,
        refreshAllowed: Boolean = true,
    ): JsonObject {
        val generation = sessionGeneration
        if (authenticated) ensureSessionScope()
        checkSession(generation)
        val session = if (authenticated) requestSession() else {
            val state = sessionState.load()
            RequestSession(state.generation, null, null, null, null, state.visitor, WEB_REMIX_VERSION)
        }
        if (authenticated && session.cookie == null) throw NotSignedInException()
        val body = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", playerClient.clientName)
                    put("clientVersion", playerClient.clientVersion)
                    playerClient.osName?.let { put("osName", it) }
                    playerClient.osVersion?.let { put("osVersion", it) }
                    playerClient.deviceMake?.let { put("deviceMake", it) }
                    playerClient.deviceModel?.let { put("deviceModel", it) }
                    playerClient.androidSdkVersion?.let { put("androidSdkVersion", it.toInt()) }
                    put("hl", "en")
                    put("gl", "US")
                    session.visitor?.let { put("visitorData", it) }
                }
                if (authenticated) putJsonObject("user") {
                    session.dataSyncId?.let { put("onBehalfOfUser", it) }
                    put("lockedSafetyMode", false)
                }
            }
            put("videoId", videoId)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            if (playerClient.needsSignatureTimestamp && signatureTimestamp != null) {
                putJsonObject("playbackContext") {
                    putJsonObject("contentPlaybackContext") {
                        put("signatureTimestamp", signatureTimestamp)
                    }
                }
            }
        }
        val headers = buildMap {
            put("User-Agent", playerClient.userAgent)
            put("X-YouTube-Client-Name", playerClient.clientId)
            put("X-YouTube-Client-Version", playerClient.clientVersion)
            playerClient.origin?.let { put("Origin", it) }
            playerClient.referer?.let { put("Referer", it) }
            session.visitor?.let { put("X-Goog-Visitor-Id", it) }
            if (authenticated) {
                put("Origin", playerClient.apiOrigin)
                put("X-Origin", playerClient.apiOrigin)
                putAll(authHeaders(session, playerClient.apiOrigin))
            }
        }
        val text = try { withRetry("player/${playerClient.clientName}") {
            checkSession(generation)
            playerTransport(MusicRequest("${playerClient.apiBase}/player",
                json.encodeToString(JsonObject.serializer(), body), headers, mapOf("prettyPrint" to "false")))
        } } catch (error: HttpStatusException) {
            if (authenticated && error.status == 401) {
                checkSession(generation)
                if (refreshAllowed) {
                    updateSession { if (it.generation == generation) it.copy(scope = null) else it }
                    return postPlayer(videoId, playerClient, signatureTimestamp, authenticated, refreshAllowed = false)
                }
                throw PlayerAuthenticationException()
            }
            throw error
        }
        checkSession(generation)
        return json.parseToJsonElement(text) as? JsonObject
            ?: error("innertube player: unexpected response shape")
    }

    /**
     * The origin a signed-in [player] call for this client has to be signed
     * for.
     *
     * Google recomputes the SAPISIDHASH digest over the origin it sees and
     * rejects a mismatch with 401, so an app client posting to
     * `www.youtube.com` signed for the music origin is not a weaker request —
     * it is a refused one. That would have made the signed-in retries look like
     * dead ends for every client that is not browser-shaped.
     */
    private val PlayerClient.apiOrigin: String
        get() = origin ?: if (usesMusicHost) MUSIC_ORIGIN else YOUTUBE_ORIGIN

    /** See [Http.postJson]'s timeout — upstream's per-player-call ceiling. */
    private const val PLAYER_TIMEOUT_MS = 6_000L

    /**
     * The session headers every signed-in WEB_REMIX request carries: the
     * cookie itself, which account in the jar, and Google's SAPISIDHASH
     * signature over the origin this request is going to. Google recomputes
     * the digest over the origin it sees and rejects a mismatch with 401.
     */
    internal fun authHeaders(origin: String = MUSIC_ORIGIN): Map<String, String> =
        authHeaders(requestSession(), origin)

    internal fun authHeaders(session: RequestSession, origin: String): Map<String, String> = buildMap {
        require(origin == MUSIC_ORIGIN || origin == YOUTUBE_ORIGIN) { "Untrusted authentication origin" }
        val cookie = session.cookie ?: return@buildMap
        put("Cookie", cookie)
        session.authUser?.let { put("X-Goog-AuthUser", it) }
        session.pageId?.let { put("X-Goog-PageId", it) }
        sapisidFrom(cookie)?.let { put("Authorization", sapisidHash(it, origin)) }
    }

    /**
     * Whether a cookie header carries a secret Innertube requests can be
     * signed with. Matched on the cookie *name* — a substring test accepts
     * `__Secure-3PAPISID` as `SAPISID` and then sends the cookie unsigned.
     */
    fun hasApiSid(cookieHeader: String): Boolean =
        cookieHeader.split(';').any { entry ->
            val name = entry.substringBefore('=').trim()
            val value = entry.substringAfter('=', "").trim()
            name in SAPISID_NAMES && value.isNotEmpty()
        }

    /**
     * The API-signing secret out of a cookie header. Three names for one
     * value, and all three have to be looked for: on a cookie-partitioned
     * login Google sets only the `__Secure-` forms. Any of them signs a
     * request; the digest does not care which it came from.
     */
    fun sapisidFrom(cookieHeader: String): String? {
        val jar = cookieHeader.split(';')
            .mapNotNull { entry ->
                val name = entry.substringBefore('=').trim()
                val value = entry.substringAfter('=', "").trim()
                if (name.isEmpty() || value.isEmpty()) null else name to value
            }
            .toMap()
        return SAPISID_NAMES.firstNotNullOfOrNull { jar[it] }
    }

    private val SAPISID_NAMES =
        listOf("SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID")

    /** `SAPISIDHASH <ts>_<sha1("<ts> <sapisid> <origin>")>` — Google's scheme. */
    fun sapisidHash(sapisid: String, origin: String = MUSIC_ORIGIN): String {
        val timestamp = Clock.System.now().toEpochMilliseconds() / 1000
        val digest = Sha1.hex("$timestamp $sapisid $origin".encodeToByteArray())
        return "SAPISIDHASH ${timestamp}_$digest"
    }
}

/**
 * The verdict of a ranged GET on a freshly minted stream URL.
 *
 * [expected] is the mime type of the format the URL was minted for, and the content
 * type is judged against *it* rather than against "must be audio". That distinction
 * is the whole reason this is a parameter. A format with no adaptive audio left —
 * which is what a guest session is handed for most of the catalogue — is a muxed
 * `video/mp4` carrying AAC, [StreamResolver] takes it deliberately, and the engine
 * demuxes the audio track out of it: `native-core`'s track search looks for a track
 * that has audio and names muxed itag 18 in the comment above it. A test that insisted
 * the answer begin `audio/` threw away the only rung the ladder had, and a track that
 * resolved on a guest session resolved on nothing.
 */
internal fun ProbeResult.classify(expected: String? = null): ProbeVerdict = when {
    status in REFUSAL_STATUSES -> ProbeVerdict.REFUSED
    status !in 200..299 && status != 416 -> ProbeVerdict.UNREACHABLE
    // 416 is the end of the file and has no body to judge: a seek past the
    // container's length, which the reader treats as a clean finish.
    status == 416 -> ProbeVerdict.UNREACHABLE
    !contentType.isMediaFamilyOf(expected) -> ProbeVerdict.REFUSED
    !bodyArrived -> ProbeVerdict.UNREACHABLE
    else -> ProbeVerdict.OK
}

/** Answers that mean *this client is being refused*, rather than a bad minute. */
private val REFUSAL_STATUSES = setOf(403, 404, 410)

/**
 * Whether a content type is the kind of media [expected] asked for.
 *
 * A family rather than an equality, and that is deliberate in both directions. A
 * range for a muxed `video/mp4` is answered `video/mp4` by one server and
 * `audio/mp4` by another for the same bytes, while a `text/html` body — the shape a
 * bot check or a consent page takes — matches no family at all, and that is the case
 * this test earns its keep on.
 *
 * `application/octet-stream` matches anything, because a server declining to name a
 * type is not the same as one naming a wrong type.
 *
 * A null [expected] means nothing was asked for, and then only the outright wrong
 * answers are refused: the check is here to catch an error page, not to insist on a
 * spelling.
 */
private fun String?.isMediaFamilyOf(expected: String?): Boolean {
    val answer = this?.substringBefore(';')?.trim()?.lowercase().orEmpty()
    // A server declining to name a type is not naming a wrong one.
    if (answer == "application/octet-stream") return true
    // Only the two families the engine can take audio out of. With no format to
    // compare against this is the whole test, and it is why an error page is refused
    // rather than waved through: `text/html` has a slash in it too.
    val family = answer.substringBefore('/')
    if (family != "audio" && family != "video") return false
    val wanted = expected?.substringBefore(';')?.trim()?.lowercase()?.substringBefore('/')
        ?.takeIf { it == "audio" || it == "video" }
    return wanted == null || wanted == family
}

internal enum class ProbeVerdict {
    /** Served media bytes; safe to play. */
    OK,

    /** Answered, but refused this request — the client is the problem. */
    REFUSED,

    /** Never got an answer worth interpreting; blame nothing in particular. */
    UNREACHABLE,
}
