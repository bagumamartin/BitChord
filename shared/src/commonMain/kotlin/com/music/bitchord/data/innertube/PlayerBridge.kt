package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.metrolist.innertubex.extraction.StreamResolveException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.AtomicLong
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.time.TimeMark
import kotlin.time.TimeSource
import kotlin.time.Duration.Companion.minutes

/**
 * Swift-facing seam over [StreamResolver].
 *
 * Thin on purpose. The resolution *policy* — which clients to ask, what to
 * remember between attempts, when to stand an identity down, and the signed-in
 * retries that are the difference between a bot check and a playable track —
 * lives in [StreamResolver], which mirrors upstream's own split between the
 * resolver and the FFI-shaped callers. This used to *be* the resolver, and being
 * both is how it ended up with no memory between calls and a global mutex
 * serialising every stream in the app.
 */
@OptIn(ExperimentalAtomicApi::class)
object PlayerBridge {
    private val ids = AtomicLong(0)
    private val jobs = AtomicReference<Map<Long, Job>>(emptyMap())
    private fun updateJobs(change: (Map<Long, Job>) -> Map<Long, Job>) {
        while (true) { val old = jobs.load(); if (jobs.compareAndSet(old, change(old))) return }
    }
    fun cancelResolve(requestId: Long) { jobs.load()[requestId]?.cancel() }

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val json = Json { ignoreUnknownKeys = true }

    fun interface ResolveCallback {
        fun onResult(json: String?, message: String?)
    }

    fun resolve(videoId: String, callback: ResolveCallback) {
        resolve(videoId, Int.MAX_VALUE, callback)
    }

    fun resolve(videoId: String, maxKbps: Int, callback: ResolveCallback) {
        resolveRequest(videoId, maxKbps, callback)
    }

    /** Cancellable replacement; older one-result entry points remain available. */
    fun resolveRequest(videoId: String, maxKbps: Int, callback: ResolveCallback): Long {
        val id = ids.addAndFetch(1)
        val generation = Innertube.sessionGeneration
        val job = bridgeScope.launch(start = CoroutineStart.LAZY) {
            try {
                Innertube.checkSession(generation)
                val resolved = StreamResolver.resolve(videoId, maxKbps)
                    ?: throw IllegalStateException("No playable stream for $videoId")
                val payload = StreamPayload(
                    url = resolved.url,
                    kbps = resolved.kbps,
                    mimeType = resolved.mimeType,
                    headers = resolved.headers,
                    loudnessDb = resolved.loudnessDb,
                    durationSeconds = resolved.durationSeconds,
                    clientName = resolved.clientName,
                )
                Innertube.checkSession(generation)
                callback.onResult(json.encodeToString(StreamPayload.serializer(), payload), null)
            } catch (e: StreamResolver.PermanentlyUnplayableException) {
                // A verdict, not a failure. Carried in the message so the caller can
                // show it as a sentence rather than an error, which is the whole
                // reason it is its own type.
                callback.onResult(null, e.message ?: "This track cannot be played")
            } catch (e: Throwable) {
                DebugLog.e("resolve failed for $videoId", e)
                callback.onResult(null, (e.message ?: e.toString()) +
                    clientOutcomes(e, CleanVisionClient.declinedReason(videoId)))
            } finally { updateJobs { it - id } }
        }
        updateJobs { it + (id to job) }
        job.start()
        return id
    }

    /**
     * Feed a refusal observed on the *playback* path back into the resolver.
     *
     * No probe runs after playback starts, so nothing else would ever find out
     * that a URL which served bytes once has stopped. Without this the client
     * stays preferred and the URL stays cached, and every following track fails the
     * same way until the app is restarted.
     */
    fun forgetPlaybackUrl(videoId: String) { StreamResolver.forgetPlaybackUrl(videoId) }

    fun onPlaybackRefused(url: String, responseCode: Int) {
        StreamResolver.onPlaybackRefused(url, responseCode)
    }

    /** Separates the sentence Swift words for a listener from the per-client detail after it. */
    const val CLIENTS_MARKER = "\n[clients]"

    /**
     * What each client YouTube was asked answered, for the Diagnostic Report.
     *
     * The extractor keeps these on its exception, but only the message used to
     * cross to Swift, so a report from a listener whose every track failed said
     * "No playable stream found" and nothing about which client refused or why.
     * Client names and outcomes only: no URLs, user agents or account details.
     */
    internal fun clientOutcomes(error: Throwable, cleanDeclined: String? = null): String {
        var cause: Throwable? = error
        while (cause != null && cause !is StreamResolveException) cause = cause.cause
        val diagnostics = (cause as? StreamResolveException)?.diagnostics
        val outcomes = listOfNotNull(cleanDeclined?.let { "${CleanVisionClient.PROFILE}=$it" }) +
            diagnostics?.attempts.orEmpty().map { "${it.clientName}=${it.outcome}" }
        if (outcomes.isEmpty()) return ""
        val page = if (diagnostics?.usedAuthenticatedWatchPage == true) " authenticatedPage" else ""
        return CLIENTS_MARKER + page + " " + outcomes.joinToString()
    }

    fun interface DoneCallback { fun onDone() }

    /** Rebuild the extraction session for a track every client refused; [callback] fires when it is done. */
    fun rebuildSession(videoId: String, callback: DoneCallback) {
        bridgeScope.launch {
            try { StreamResolver.rebuildSession(videoId) }
            catch (e: Throwable) { DebugLog.e("session rebuild failed for $videoId", e) }
            finally { callback.onDone() }
        }
    }

    /**
     * The track's AVC/MP4 video side (O9), or a payload with a null `url` when
     * the track has none — an art track or a video-only-in-WebM upload. That is
     * a normal answer, not an error: the host keeps the artwork.
     *
     * Deliberately not cancellable: the host asks once per track and can ignore
     * a late answer.
     */
    fun resolveVideo(videoId: String, forceRefresh: Boolean = false, callback: VideoCallback) {
        val generation = Innertube.sessionGeneration
        bridgeScope.launch {
            try {
                Innertube.checkSession(generation)
                val side = coalescedVideoSide(videoId, generation, forceRefresh)
                Innertube.checkSession(generation)
                callback.onResult(json.encodeToString(VideoSidePayload.serializer(), side.toPayload()), null)
            } catch (e: Throwable) {
                DebugLog.e("video side failed for $videoId", e)
                callback.onResult(null, e.message ?: e.toString())
            }
        }
    }

    // One video request per track at a time, and a short-lived answer cache:
    // several surfaces can ask for the same picture, and re-attaching a track
    // must not mint a new signed URL every time. Nothing here runs on its own —
    // a request exists only because a caller asked for a surface.
    private val videoLock = Mutex()
    private val videoFlights = mutableMapOf<String, Deferred<VideoSide?>>()
    private val videoCache = mutableMapOf<String, Pair<TimeMark, VideoSide?>>()

    /** Test seam: the network call the coalescer shares. */
    internal var videoSideLoader: suspend (String) -> VideoSide? = { UpstreamPlaybackExtractor.videoSide(it) }

    private suspend fun coalescedVideoSide(videoId: String, generation: Long, forceRefresh: Boolean): VideoSide? {
        val key = "$generation|$videoId"
        val flight = videoLock.withLock {
            if (forceRefresh) videoCache.remove(key)
            else videoCache[key]?.takeIf { it.first.elapsedNow() < 5.minutes }?.let { return it.second }
            videoFlights[key] ?: bridgeScope.async(start = CoroutineStart.LAZY) {
                val side = try {
                    videoSideLoader(videoId)
                } catch (e: Throwable) {
                    videoLock.withLock { videoFlights.remove(key) }
                    throw e
                }
                videoLock.withLock {
                    // A null answer (no AVC side, or a refusal) is not cached:
                    // it may be transient, and it is the rare answer anyway.
                    if (side != null) {
                        if (videoCache.size >= 16) videoCache.clear()
                        videoCache[key] = TimeSource.Monotonic.markNow() to side
                    }
                    videoFlights.remove(key)
                }
                side
            }.also { videoFlights[key] = it }
        }
        flight.start()
        return flight.await()
    }

    fun interface VideoCallback {
        fun onResult(json: String?, message: String?)
    }

    @Serializable
    data class VideoSidePayload(
        val url: String? = null,
        val width: Int? = null,
        val height: Int? = null,
        val itag: Int? = null,
        val mimeType: String? = null,
        val codecs: String? = null,
        val bitrate: Int? = null,
        val headers: Map<String, String> = emptyMap(),
        val availableVideoHeights: List<Int> = emptyList(),
        val urlHasNParameter: Boolean = false,
        val clientName: String,
        val profileId: String,
        val musicVideoType: String? = null,
    )

    private fun VideoSide?.toPayload() = VideoSidePayload(
        url = this?.url,
        width = this?.width,
        height = this?.height,
        itag = this?.itag,
        mimeType = this?.mimeType,
        codecs = this?.codecs,
        bitrate = this?.bitrate,
        headers = this?.headers ?: emptyMap(),
        availableVideoHeights = this?.availableVideoHeights ?: emptyList(),
        urlHasNParameter = this?.urlHasNParameter ?: false,
        clientName = this?.clientName ?: "VISIONOS",
        profileId = this?.profileId ?: "VISIONOS_0_1",
        musicVideoType = this?.musicVideoType,
    )

    @Serializable
    data class StreamPayload(
        val url: String,
        val kbps: Int,
        val mimeType: String,
        val headers: Map<String, String> = emptyMap(),
        /** Absent (null) on payloads minted before the figure was parsed. */
        val loudnessDb: Double? = null,
        val durationSeconds: Long? = null,
        val clientName: String = "unknown",
    )
}
