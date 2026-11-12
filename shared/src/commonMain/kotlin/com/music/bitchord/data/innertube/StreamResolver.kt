package com.music.bitchord.data.innertube
import com.music.bitchord.data.DebugLog
import com.metrolist.innertubex.extraction.StreamResolveException
import com.music.bitchord.data.http.ProbeResult
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.RawHttpBytes
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.time.TimeMark
import kotlin.time.TimeSource
import kotlin.time.Duration.Companion.seconds

/** Maintained upstream extraction, with account-scoped coalescing and short-lived media URLs. */
@OptIn(ExperimentalAtomicApi::class)
object StreamResolver {
    data class ResolvedStream(val url: String, val kbps: Int, val mimeType: String,
                              val headers: Map<String, String>, val loudnessDb: Double? = null,
                              val durationSeconds: Long? = null, val clientName: String = "unknown")
    class PermanentlyUnplayableException(reason: String) : Exception(reason)
    private class Resolved(val stream: ResolvedStream, val generation: Long, val at: TimeMark)
    private val recent = CowMap<String, Resolved>()
    private data class Flight(val job: Deferred<ResolvedStream>, val waiters: Int)
    private val inFlight = CowMap<String, Flight>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    internal var extraction: suspend (String, Int) -> ResolvedStream? = { id, ceiling -> UpstreamPlaybackExtractor.extract(id, ceiling) }
    internal var rebuild: suspend (String) -> Unit = { UpstreamPlaybackExtractor.rebuildSession(it) }
    suspend fun resolve(videoId: String, maxKbps: Int = Int.MAX_VALUE): ResolvedStream? {
        val generation = Innertube.sessionGeneration
        val key = "$generation|$videoId|$maxKbps"
        recent.snapshot()[key]?.takeIf { it.at.elapsedNow() < 20.seconds }?.let { return it.stream }
        botCheckedUntil.load()?.takeIf { it.hasNotPassedNow() }?.let { throw BotCheckException() }
        failed.snapshot()[videoId]?.let { if (it.at.elapsedNow() < FAILURE_MEMORY) throw it.cause }
        val candidate = scope.async(start = CoroutineStart.LAZY) {
            Innertube.checkSession(generation)
            val stream = try {
                extraction(videoId, maxKbps)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (isBotChecked(videoId, e)) throw BotCheckException(signedIn = Innertube.cookie != null)
                remember(videoId, e)
                throw e
            } ?: run {
                if (isBotChecked(videoId, null)) throw BotCheckException(signedIn = Innertube.cookie != null)
                throw IllegalStateException("No playable stream for $videoId").also { remember(videoId, it) }
            }
            Innertube.checkSession(generation)
            // Validate on the first bounded media range, which is also the
            // first request capable of producing sound. A separate probe
            // duplicated the CDN round trip and could validate a different
            // URL path from the one the downloader actually consumed.
            stream
        }
        var selected = candidate
        inFlight.update { map ->
            val existing = map[key]
            if (existing == null) { selected = candidate; map[key] = Flight(candidate, 1) }
            else { selected = existing.job; map[key] = existing.copy(waiters = existing.waiters + 1) }
        }
        if (selected !== candidate) candidate.cancel()
        selected.start()
        try {
            val stream = selected.await()
            Innertube.checkSession(generation)
            recent.update { map ->
                if (map.size >= 32) map.clear()
                map[key] = Resolved(stream, generation, TimeSource.Monotonic.markNow())
            }
            return stream
        } finally {
            var abandoned: Deferred<ResolvedStream>? = null
            inFlight.update { map ->
                val flight = map[key]
                if (flight?.job === selected) {
                    if (flight.waiters <= 1) { map.remove(key); abandoned = flight.job }
                    else { map[key] = flight.copy(waiters = flight.waiters - 1); abandoned = null }
                }
            }
            abandoned?.cancel()
        }
    }
    /**
     * YouTube's "Sign in to confirm you're not a bot": a verdict on the network
     * address, not on any track. Every client gets it, so walking clients,
     * rebuilding the session or trying another copy only adds traffic from an
     * address already under suspicion. It is told apart from an ordinary miss
     * by one anonymous player request, and then nothing more is asked of
     * YouTube for [BOT_CHECK_BACKOFF] — a network change or a little patience
     * is what clears it.
     *
     * `signedIn` says the verdict came back for the account's own requests, so
     * the listener is not told to sign in when they already are.
     */
    class BotCheckException(signedIn: Boolean = false) : IllegalStateException(
        if (signedIn) "YouTube asks this network to confirm it is not a bot, even signed in"
        else "YouTube asks this network to sign in to confirm it is not a bot"
    )
    private val botCheckedUntil = AtomicReference<TimeMark?>(null)
    private val BOT_CHECK_BACKOFF = 120.seconds

    /**
     * Whether [failure] was YouTube's bot check, judged by the identity that
     * actually asked.
     *
     * The extraction's own per-client outcomes come first: a bot check shows as
     * every client that was really asked answering `LOGIN_REQUIRED`. The
     * anonymous probe below is only evidence for an anonymous listener. Asked
     * on a signed-in listener's behalf it speaks for a different identity —
     * anonymous requests from a busy address are challenged long before the
     * account's are — and it used to turn every signed-in failure (a stale
     * player config, a refused client) into "confirm you're not a bot", then
     * hold every track behind that verdict for two minutes, skipping the
     * session rebuild that would have fixed the real problem.
     */
    private suspend fun isBotChecked(videoId: String, failure: Throwable?): Boolean {
        val asked = (failure as? StreamResolveException)?.diagnostics?.attempts.orEmpty()
            .filterNot { it.outcome.startsWith("selection:") }
        val signedIn = Innertube.cookie != null
        val allLoginRequired = asked.isNotEmpty() && asked.all { it.outcome == "playability:LOGIN_REQUIRED" }
        val verdict = when {
            signedIn -> allLoginRequired
            asked.isNotEmpty() && !allLoginRequired -> false
            else -> anonymousProbeSaysBot(videoId)
        }
        if (!verdict) {
            if (signedIn && asked.isNotEmpty()) {
                DebugLog.d("$videoId: signed-in extraction failed without a bot check: " +
                    asked.joinToString { "${it.clientName}=${it.outcome}" })
            }
            return false
        }
        botCheckedUntil.store(TimeSource.Monotonic.markNow() + BOT_CHECK_BACKOFF)
        DebugLog.w("YouTube is bot-checking this network${if (signedIn) " (signed in)" else ""}; " +
            "not asking again for ${BOT_CHECK_BACKOFF.inWholeSeconds}s")
        return true
    }

    private suspend fun anonymousProbeSaysBot(videoId: String): Boolean {
        val reason = try {
            val body = Http.client.post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false") {
                contentType(ContentType.Application.Json)
                setBody(buildJsonObject {
                    put("videoId", videoId)
                    putJsonObject("context") {
                        putJsonObject("client") {
                            put("clientName", "ANDROID_VR")
                            put("clientVersion", "1.65.10")
                            put("androidSdkVersion", 32)
                            put("hl", "en")
                        }
                    }
                }.toString())
            }.bodyAsText()
            (Json.parseToJsonElement(body).jsonObject["playabilityStatus"] as? JsonObject)
                ?.get("reason")?.jsonPrimitive?.contentOrNull.orEmpty()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            return false
        }
        return reason.contains("not a bot", ignoreCase = true)
    }

    /**
     * A track every client just failed is not asked for again for
     * [FAILURE_MEMORY], and the session is rebuilt at most once per
     * [REBUILD_SPACING].
     *
     * A failed track used to be asked for again by everything that could ask:
     * the rebuilt session, the counterpart lookup, the queue coming back round,
     * a listener tapping it twice. One report showed ten failed extractions and
     * five session rebuilds for a single track in forty seconds — each one a
     * walk through every client from the same address, which is the traffic
     * that gets an address challenged. The one retry that can help, on a
     * rebuilt session, still happens; the rest get the answer already given.
     */
    private class Failed(val cause: Throwable, val at: TimeMark)
    private val failed = CowMap<String, Failed>()
    private val FAILURE_MEMORY = 30.seconds
    private val REBUILD_SPACING = 60.seconds
    private val rebuiltAt = AtomicReference<TimeMark?>(null)
    private fun remember(videoId: String, cause: Throwable) {
        val entry = Failed(cause, TimeSource.Monotonic.markNow())
        failed.update { map ->
            map.entries.removeAll { it.value.at.elapsedNow() >= FAILURE_MEMORY }
            map[videoId] = entry
        }
    }

    fun onSessionChanged() {
        inFlight.snapshot().values.forEach { it.job.cancel() }; inFlight.clear(); recent.clear()
        failed.clear(); rebuiltAt.store(null)
        botCheckedUntil.store(null)
        DebugLog.d("session changed; cleared upstream resolver flights and media URLs")
    }
    fun forgetPlaybackUrl(videoId: String) {
        recent.update { map -> map.entries.removeAll { it.key.split("|").getOrNull(1) == videoId } }
    }

    fun onPlaybackRefused(url: String, responseCode: Int) {
        if (responseCode !in setOf(403, 404, 410)) return
        recent.update { map -> map.entries.removeAll { it.value.stream.url == url } }
        UpstreamPlaybackExtractor.onRefused(url)
        DebugLog.w("served media URL refused; next resolution will use fresh upstream extraction")
    }
    /** See [UpstreamPlaybackExtractor.rebuildSession]; also drops this track's remembered URLs. */
    suspend fun rebuildSession(videoId: String) {
        val last = rebuiltAt.load()
        if (last != null && last.elapsedNow() < REBUILD_SPACING) {
            DebugLog.w("$videoId: session was rebuilt ${last.elapsedNow().inWholeSeconds}s ago; not rebuilding again yet")
            return
        }
        rebuiltAt.store(TimeSource.Monotonic.markNow())
        recent.update { map -> map.entries.removeAll { it.key.split("|").getOrNull(1) == videoId } }
        failed.update { it.remove(videoId) }
        rebuild(videoId)
        DebugLog.w("$videoId: every client refused; rebuilt the extraction session")
    }
    fun onFirstRangeRejected(url: String, responseCode: Int, excludeClient: Boolean) {
        recent.update { map -> map.entries.removeAll { it.value.stream.url == url } }
        UpstreamPlaybackExtractor.onRefused(url, excludeClient = excludeClient)
        DebugLog.w("first media range rejected (HTTP $responseCode); retrying upstream extraction")
    }
    internal class AudioFormat(
        val url: String?,
        val signatureCipher: String?,
        val mimeType: String,
        val kbps: Int,
    )

    /** Playable renditions within the selected data budget, ranked by codec tier.
     * Broken cipher solving makes unciphered formats preferable within that
     * budget; it never authorizes silently downloading an over-budget stream.
     */
    internal fun rankForPlayback(response: JsonObject, maxKbps: Int, signatureBroken: Boolean = SignatureSolver.isBroken): List<AudioFormat> {
        val within = audioFormats(response).filter {
            (it.kbps > 0 && it.kbps <= maxKbps) || (it.kbps == 0 && maxKbps == Int.MAX_VALUE)
        }
        val uncipheredFirst = compareByDescending<AudioFormat> { it.url != null }
        val fidelity = compareByDescending<AudioFormat> {
            if (it.mimeType.contains("opus", ignoreCase = true) && it.kbps >= 128) 2
            else if (it.kbps >= 192) 2 else if (it.kbps >= 96) 1 else 0
        }.thenByDescending { it.mimeType.contains("opus", ignoreCase = true) }
            .thenByDescending { it.kbps }.then(uncipheredFirst)
        return within.sortedWith(if (signatureBroken) uncipheredFirst.then(fidelity) else fidelity)
    }

    private fun audioFormats(response: JsonObject): List<AudioFormat> {
        val streamingData = response["streamingData"] as? JsonObject ?: return emptyList()
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return (adaptive + legacy).filterIsInstance<JsonObject>().mapNotNull { it.toAudioFormat() }
    }

    /**
     * How many formats the response held, playable or not.
     *
     * For the line that says what a client did *not* give us. Counting the audio
     * entries here would make the number agree with the filter and say nothing; the
     * useful number is what arrived.
     */
    private fun countFormats(response: JsonObject): Int {
        val streamingData = response["streamingData"] as? JsonObject ?: return 0
        val adaptive = (streamingData["adaptiveFormats"] as? JsonArray).orEmpty()
        val legacy = (streamingData["formats"] as? JsonArray).orEmpty()
        return adaptive.size + legacy.size
    }

    /**
     * Audio-only, or muxed MP4 that still carries AAC — the remaining guest format
     * when adaptive audio is SABR-only.
     */
    private fun JsonObject.toAudioFormat(): AudioFormat? {
        val mime = (get("mimeType") as? JsonPrimitive)?.contentOrNull ?: return null
        val audioOnly = mime.startsWith("audio/")
        val muxedAac = mime.startsWith("video/mp4") && mime.contains("mp4a", ignoreCase = true)
        if (!audioOnly && !muxedAac) return null
        // AAC and Opus are both supported by the Apple native decoder.
        val url = (get("url") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
        val cipher = (get("signatureCipher") as? JsonPrimitive)?.contentOrNull
            ?: (get("cipher") as? JsonPrimitive)?.contentOrNull
        if (url == null && cipher == null) return null
        val bps = (get("bitrate") as? JsonPrimitive)?.intOrNull ?: 0
        return AudioFormat(url, cipher, mime, (bps / 1000).coerceAtLeast(0))
    }

}

/** Reject ignored Range requests: accepting a bounded 200 body would truncate audio. */
internal fun validateFirstMediaRange(response: RawHttpBytes, expectedMimeType: String? = null): ByteArray {
    val bytes = response.body ?: ByteArray(0)
    val verdict = ProbeResult(
        status = response.status,
        contentType = response.contentType,
        bodyArrived = bytes.isNotEmpty(),
    ).classify(expectedMimeType)
    if (response.status != 206 || verdict != ProbeVerdict.OK || bytes.size < MIN_FIRST_RANGE_BYTES) {
        throw InvalidFirstMediaRangeException(response.status,
            "Invalid first media range: HTTP ${response.status}, content-type ${response.contentType ?: "missing"}"
        )
    }
    return bytes
}

internal const val MIN_FIRST_RANGE_BYTES = 4 * 1024
internal class InvalidFirstMediaRangeException(val responseCode: Int, message: String) : Exception(message)

@OptIn(ExperimentalAtomicApi::class)
private class CowMap<K : Any, V : Any> {

    private val ref = AtomicReference<Map<K, V>>(emptyMap())

    fun snapshot(): Map<K, V> = ref.load()

    fun update(block: (MutableMap<K, V>) -> Unit) {
        while (true) {
            val current = ref.load()
            val next = LinkedHashMap(current)
            block(next)
            if (ref.compareAndSet(current, next)) return
        }
    }

    fun clear() {
        ref.store(emptyMap())
    }
}
