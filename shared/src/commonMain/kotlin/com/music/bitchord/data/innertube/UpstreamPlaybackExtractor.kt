package com.music.bitchord.data.innertube

import com.metrolist.innertubex.InnerTube
import com.metrolist.innertubex.InnerTubeLogger
import com.metrolist.innertubex.cipher.PlayerConfigRepository
import com.metrolist.innertubex.cipher.RemotePlayerConfigStore
import com.metrolist.innertubex.cipher.YouTubeCipherService
import com.metrolist.innertubex.extraction.AudioQuality
import com.metrolist.innertubex.extraction.ContentHints
import com.metrolist.innertubex.extraction.ExtractedStream
import com.metrolist.innertubex.extraction.InnerTubeExtractor
import com.metrolist.innertubex.extraction.generateClientPlaybackNonce
import com.metrolist.innertubex.models.YouTubeClient
import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import io.ktor.client.statement.bodyAsText
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.time.TimeSource
import kotlin.time.TimeMark
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The video side of a track: one AVC/MP4 rendition the Apple picture player can
 * actually decode.
 *
 * The extraction stack returns the single rendition *it* selected, which is
 * often VP9/WebM; `AVPlayer` cannot render that. So the video side is chosen
 * here from the same visitor-backed profile's player response, AVC only, and
 * only when the URL is a ready media URL. Null means the track has no usable
 * video side and the artwork stays.
 */
internal data class VideoSide(
    val url: String,
    val width: Int?,
    val height: Int?,
    val itag: Int?,
    val mimeType: String,
    val codecs: String?,
    val bitrate: Int?,
    val headers: Map<String, String>,
    val availableVideoHeights: List<Int>,
    val urlHasNParameter: Boolean,
    val clientName: String,
    val profileId: String,
    val musicVideoType: String?,
)

/** Same maintained extraction stack as Android upstream, on the shared Darwin transport. */
@OptIn(ExperimentalAtomicApi::class)
internal object UpstreamPlaybackExtractor {
    /** Upstream's deck caps a music video at 1080p (videoDeck.ts `maxHeight`). */
    private const val MAX_VIDEO_HEIGHT = 1080

    /**
     * The visitor-backed profile the audio path actually resolves through. Its
     * automatic video selection is refused ("legacy direct playback verified
     * for normal audio only"), but a direct request to it answers with both
     * AVC/MP4 and VP9/WebM renditions; only the former is decoded here.
     */
    private val VIDEO_CLIENT = YouTubeClient.VISIONOS_0_1
    private const val VIDEO_PROFILE = "VISIONOS_0_1"

    /** The extractor's own n-parameter test, which is private there. */
    private val N_PARAMETER_REGEX = Regex("(?:[?&]|%26)n(?:=|%3[dD])", RegexOption.IGNORE_CASE)
    private val CODECS_REGEX = Regex("codecs=\"([^\"]+)\"")

    private class Session(val generation: Long, val innerTube: InnerTube, val extractor: InnerTubeExtractor, val cipher: YouTubeCipherService)
    private data class Issued(val id: String, val profile: String, val generation: Long)
    private val refreshScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val issued = AtomicReference<Map<String, Issued>>(emptyMap())
    private val excluded = AtomicReference<Map<String, TimeMark>>(emptyMap())
    fun onRefused(url: String, excludeClient: Boolean = false) {
        val origin = issued.load()[url] ?: return
        if (origin.generation != Innertube.sessionGeneration) return
        if (excludeClient) while (true) {
            val old = excluded.load()
            val next = (if (old.size >= 64) emptyMap() else old) + ("${origin.generation}:${origin.id}:${origin.profile}" to TimeSource.Monotonic.markNow())
            if (excluded.compareAndSet(old, next)) break
        }
        refreshScope.launch {
            lock.withLock { session?.takeIf { it.generation == origin.generation }?.cipher }
                ?.let { runCatching { it.refreshAfterStreamRejection() } }
        }
    }
    /**
     * Starts extraction over for [videoId]: a new player config, cipher and
     * PoToken binding, with the clients that refused this track forgiven.
     *
     * For when every client refused the same track within seconds. That is far
     * more often a session that has fallen out of favour (a stale player config,
     * a token bound to an old challenge) than a track that cannot play, and the
     * clients it refused deserve one more ask once the session is new.
     */
    suspend fun rebuildSession(videoId: String) {
        lock.withLock {
            session?.let { it.innerTube.close(); it.cipher.dispose() }
            session = null
        }
        while (true) {
            val old = excluded.load()
            val next = old.filterKeys { it.split(":").getOrNull(1) != videoId }
            if (excluded.compareAndSet(old, next)) break
        }
        PlaybackTokenBridge.invalidate()
    }
    private val lock = Mutex()
    private var session: Session? = null
    private val logger = InnerTubeLogger { event ->
        // Library diagnostics may contain signed URLs. The shared redactor is
        // applied before anything reaches the system log; never print details maps.
        DebugLog.d("ITX ${event.tag}: ${event.message}")
    }
    private suspend fun current(): Session {
        val generation = Innertube.sessionGeneration
        if (Innertube.cookie != null) Innertube.ensureSessionScope()
        Innertube.checkSession(generation)
        return lock.withLock {
            session?.takeIf { it.generation == generation }?.let { return@withLock it }
            session?.let { it.innerTube.close(); it.cipher.dispose() }
            val snapshot = Innertube.requestSession()
            val tube = InnerTube(Http.client, logger = logger)
            tube.replaceSession(snapshot.cookie, snapshot.visitor, snapshot.dataSyncId,
                snapshot.authUser ?: "0", useLoginForBrowse = snapshot.cookie != null)
            val repository = object : PlayerConfigRepository {
                override val enabled = true
                override val sourceUrl = "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json"
                override val defaultSourceUrl = sourceUrl
                override var cachedJson = ""
                override var cachedAtMs = 0L
                override var cachedSourceUrl = ""
                override var cachedEtag = ""
            }
            val store = RemotePlayerConfigStore(Http.client, repository, logger)
            val cipher = YouTubeCipherService(Http.client, store, logger)
            val extractor = InnerTubeExtractor(
                configParser = com.metrolist.innertubex.extraction.YtConfigParserImpl(Http.client, tube, store, cipherService = cipher),
                cipherService = cipher, innerTube = tube, tokenProvider = PlaybackTokenBridge.tokenProvider(), logger = logger)
            Session(generation, tube, extractor, cipher).also { session = it }
        }
    }
    suspend fun extract(videoId: String, maxKbps: Int): StreamResolver.ResolvedStream? {
        val stream = extractStream(videoId, maxKbps) ?: return null
        check(stream.sabrBootstrap == null) { "This audio engine requires a progressive stream" }
        while (true) {
            val old = issued.load()
            val next = (if (old.size >= 64) emptyMap() else old) + (stream.audioUrl to Issued(videoId, stream.profileId, Innertube.sessionGeneration))
            if (issued.compareAndSet(old, next)) break
        }
        DebugLog.d("$videoId: upstream ${stream.profileId} selected ${(stream.bitrate ?: 0) / 1000}kbps")
        return StreamResolver.ResolvedStream(stream.audioUrl, (stream.bitrate ?: 0) / 1000,
            stream.mimeType.orEmpty() + (stream.codecs?.let { "; codecs=\"$it\"" } ?: ""),
            stream.headers, stream.loudnessDb, stream.mediaMetadata?.durationSeconds?.takeIf { it > 0 },
            stream.profileId)
    }

    /**
     * The track's AVC/MP4 video side, from the same direct profile the audio
     * path resolves through.
     *
     * The extraction stack's own video selection picks VP9/WebM for a music
     * video (the vendored comparator ranks AVC and VP9 alike, then takes the
     * higher bitrate), which `AVPlayer` cannot decode. This makes the video-only
     * player request itself, keeps only `video/mp4` + `avc1` renditions at most
     * 1080p tall, requires a ready (n-free, allowed-host) URL, and takes the
     * highest bitrate among them. Everything unmoved stays exactly as it was:
     * the audio path never asks for video and never sees this function.
     */
    suspend fun videoSide(videoId: String): VideoSide? {
        val session = current()
        val visitor = Innertube.ensureVisitorData()
        val response = try {
            session.innerTube.player(VIDEO_CLIENT, videoId, requestVisitorData = visitor)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            DebugLog.d("$videoId: video side request refused: ${e.message}")
            return null
        }
        Innertube.checkSession(session.generation)
        val root = try {
            Json.parseToJsonElement(response.bodyAsText()).jsonObject
        } catch (e: Throwable) {
            DebugLog.d("$videoId: video side response was not JSON: ${e.message}")
            return null
        }
        val status = root["playabilityStatus"]?.jsonObject?.get("status")?.jsonPrimitive?.contentOrNull
        if (status != null && status != "OK") {
            DebugLog.d("$videoId: video side playability $status")
            return null
        }
        val formats = root["streamingData"]?.jsonObject?.get("adaptiveFormats")?.jsonArray ?: return null
        val musicVideoType = root["videoDetails"]?.jsonObject?.get("musicVideoType")?.jsonPrimitive?.contentOrNull
        val heights = mutableSetOf<Int>()
        var best: VideoSide? = null
        for (element in formats) {
            val format = element.jsonObject
            val mimeType = format["mimeType"]?.jsonPrimitive?.contentOrNull ?: continue
            if (!mimeType.startsWith("video/")) continue
            val height = format["height"]?.jsonPrimitive?.intOrNull
            if (height != null && height > 0) heights += height
            // AVC in MP4 only: AVFoundation cannot decode WebM/VP9, and AV1 is
            // hardware-only on recent chips, so neither is offered as a video side.
            // A muxed rendition carries its own audio and is not this side either.
            if (!mimeType.startsWith("video/mp4", ignoreCase = true)) continue
            if (!mimeType.contains("avc1", ignoreCase = true)) continue
            if (mimeType.contains("mp4a", ignoreCase = true)) continue
            val width = format["width"]?.jsonPrimitive?.intOrNull
            if (width == null || width <= 0 || height == null || height <= 0 || height > MAX_VIDEO_HEIGHT) continue
            val url = format["url"]?.jsonPrimitive?.contentOrNull ?: continue
            if (!isAllowedVideoUrl(url)) continue
            if (N_PARAMETER_REGEX.containsMatchIn(url)) continue
            val bitrate = format["bitrate"]?.jsonPrimitive?.intOrNull
            if (best == null || (bitrate ?: 0) > (best.bitrate ?: 0)) {
                best = VideoSide(
                    url = url,
                    width = width,
                    height = height,
                    itag = format["itag"]?.jsonPrimitive?.intOrNull,
                    mimeType = mimeType,
                    codecs = CODECS_REGEX.find(mimeType)?.groupValues?.getOrNull(1),
                    bitrate = bitrate,
                    headers = emptyMap(),
                    availableVideoHeights = emptyList(),
                    urlHasNParameter = false,
                    clientName = VIDEO_CLIENT.clientName,
                    profileId = VIDEO_PROFILE,
                    musicVideoType = musicVideoType,
                )
            }
        }
        val chosen = best?.copy(availableVideoHeights = heights.sorted())
        if (chosen == null) {
            DebugLog.d("$videoId: no AVC/MP4 video side")
        } else {
            DebugLog.d("$videoId: video side itag=${chosen.itag} ${chosen.width}x${chosen.height} ${(chosen.bitrate ?: 0) / 1000}kbps")
        }
        return chosen
    }

    /** The extractor's own media-host rule: https, port 443, `/videoplayback` on a Google host. */
    private fun isAllowedVideoUrl(value: String): Boolean =
        runCatching {
            val url = io.ktor.http.Url(value)
            url.protocol == io.ktor.http.URLProtocol.HTTPS &&
                url.port == 443 &&
                (url.host == "googlevideo.com" || url.host.endsWith(".googlevideo.com")) &&
                url.encodedPath == "/videoplayback"
        }.getOrDefault(false)

    private suspend fun extractStream(videoId: String, maxKbps: Int): ExtractedStream? {
        val session = current()
        val stream = session.extractor.extract(
            videoId = videoId,
            hints = ContentHints(
                wantVideo = false,
                maxAudioBitrateBps = maxKbps.takeIf { it < Int.MAX_VALUE }?.let {
                    (it.toLong() * 1_000L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                },
            )
                .withStreamCapabilities(allowHls = false, allowSabr = false, allowBoundedRange = true),
            excludedClients = excluded.load().filter { (key, at) ->
                key.startsWith("${session.generation}:$videoId:") && at.elapsedNow() < 5.minutes
            }.keys.map { it.substringAfterLast(":") }.toSet(),
            audioQuality = if (maxKbps <= 64) AudioQuality.LOW else AudioQuality.AUTO,
            clientPlaybackNonce = generateClientPlaybackNonce()) ?: return null
        Innertube.checkSession(session.generation)
        return stream
    }
}
