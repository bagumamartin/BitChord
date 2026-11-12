package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.hours
import kotlin.time.TimeMark
import kotlin.time.TimeSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * One anonymous visionOS player request, asked before the extraction stack.
 *
 * The visionOS client answers an ordinary song with plain audio URLs: no
 * signature, no `n` transform, no PO token, and googlevideo serves every byte
 * range of them. So the common case needs none of the machinery the extraction
 * stack carries — a watch page, a player script, a token minted in a web view —
 * and none of that machinery's ways to fail.
 *
 * It is also asked as nobody. The request carries no account, no cookie and a
 * visitor id minted for it alone, so a session YouTube has stopped trusting
 * cannot follow it here, and a visitor that is refused is thrown away rather
 * than asked again.
 *
 * Anything this client will not serve — age-restricted and private tracks, a
 * response without a ready URL — is left to the extraction stack, which is
 * asked next exactly as before.
 */
@OptIn(ExperimentalAtomicApi::class)
internal object CleanVisionClient {
    /** Names this path wherever a client is excluded, remembered or reported. */
    const val PROFILE = "VISIONOS_CLEAN"

    private const val VERSION = "1.02"
    private const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private val VISITOR_LIFETIME = 6.hours

    sealed interface Outcome {
        data class Served(val stream: StreamResolver.ResolvedStream) : Outcome
        /** [reason] is for the Diagnostic Report: a status word, never a URL or an id. */
        data class Declined(val reason: String) : Outcome
    }

    private class Visitor(val id: String, val minted: TimeMark)
    private val visitor = AtomicReference<Visitor?>(null)
    private val lastDeclined = AtomicReference<Pair<String, String>?>(null)

    internal var mintVisitor: suspend () -> String? = { Innertube.mintAnonymousVisitor() }
    internal var transport: suspend (body: String, visitor: String) -> String = { body, visitor ->
        Http.postJson(
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            body,
            headers = mapOf(
                "User-Agent" to USER_AGENT,
                "X-YouTube-Client-Name" to "101",
                "X-YouTube-Client-Version" to VERSION,
                "X-Goog-Visitor-Id" to visitor,
                "Origin" to "https://www.youtube.com",
            ),
            timeoutMillis = 8_000,
        )
    }

    /** Drop the visitor, so the next request is asked as a new one. */
    fun forgetVisitor() { visitor.store(null) }

    /** Why this client last declined [videoId], for the report on a track nothing would serve. */
    fun declinedReason(videoId: String): String? = lastDeclined.load()?.takeIf { it.first == videoId }?.second

    suspend fun resolve(videoId: String, maxKbps: Int): Outcome {
        val outcome = try {
            ask(videoId, maxKbps)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Outcome.Declined("request:${e::class.simpleName ?: "unknown"}")
        }
        if (outcome is Outcome.Declined) {
            // A refusal may be a verdict on the visitor rather than the track.
            forgetVisitor()
            lastDeclined.store(videoId to outcome.reason)
            DebugLog.d("$videoId: clean visionOS declined (${outcome.reason})")
        }
        return outcome
    }

    private suspend fun ask(videoId: String, maxKbps: Int): Outcome {
        val current = visitor.load()?.takeIf { it.minted.elapsedNow() < VISITOR_LIFETIME }
            ?: mintVisitor()?.takeIf { it.isNotBlank() }
                ?.let { Visitor(it, TimeSource.Monotonic.markNow()).also(visitor::store) }
            ?: return Outcome.Declined("visitor_unavailable")
        val response = Json.parseToJsonElement(transport(requestBody(videoId, current.id), current.id)) as? JsonObject
            ?: return Outcome.Declined("response:not_json")
        val status = ((response["playabilityStatus"] as? JsonObject)?.get("status") as? JsonPrimitive)?.contentOrNull
        if (status != "OK") return Outcome.Declined("playability:${status ?: "missing"}")
        val format = StreamResolver.rankForPlayback(response, maxKbps, signatureBroken = false).firstOrNull {
            it.mimeType.startsWith("audio/") && it.url != null && UpstreamPlaybackExtractor.isReadyMediaUrl(it.url)
        } ?: return Outcome.Declined("formats:no_ready_audio_url")
        val audioConfig = (response["playerConfig"] as? JsonObject)?.get("audioConfig") as? JsonObject
        val details = response["videoDetails"] as? JsonObject
        return Outcome.Served(
            StreamResolver.ResolvedStream(
                url = format.url!!,
                kbps = format.kbps,
                mimeType = format.mimeType,
                headers = emptyMap(),
                loudnessDb = (audioConfig?.get("loudnessDb") as? JsonPrimitive)?.doubleOrNull,
                durationSeconds = (details?.get("lengthSeconds") as? JsonPrimitive)?.longOrNull?.takeIf { it > 0 },
                clientName = PROFILE,
            )
        )
    }

    internal fun requestBody(videoId: String, visitor: String): String = buildJsonObject {
        putJsonObject("context") {
            putJsonObject("client") {
                put("clientName", "VISIONOS")
                put("clientVersion", VERSION)
                put("deviceMake", "Apple")
                put("deviceModel", "RealityDevice17,1")
                put("userAgent", USER_AGENT)
                put("osName", "visionOS")
                put("osVersion", "26.5.23O471")
                put("hl", "en")
                put("gl", "US")
                put("visitorData", visitor)
            }
        }
        put("videoId", videoId)
        put("contentCheckOk", true)
        put("racyCheckOk", true)
    }.toString()
}
