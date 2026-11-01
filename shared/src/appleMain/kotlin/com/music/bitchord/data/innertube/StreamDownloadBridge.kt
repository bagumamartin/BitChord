package com.music.bitchord.data.innertube

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.HttpStatusException
import com.music.bitchord.data.http.RawHttpBytes
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import platform.Foundation.NSMutableData
import platform.Foundation.NSFileManager
import platform.Foundation.NSLock
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import platform.Foundation.writeToFile
import platform.posix.FILE
import platform.posix.fclose
import platform.posix.fflush
import platform.posix.fopen
import platform.posix.fwrite

/**
 * Swift-facing bridge for downloading audio streams.
 *
 * Goes through [Http.getBytes], so the media fetch shares its connection context
 * with the `player` request that minted the URL and with the probe that cleared
 * it. That is upstream's rule and the reason [Http] is one client:
 *
 *  > googlevideo binds a stream URL to the connection context of the `player`
 *  > request that minted it. If Innertube and the media fetch used separate HTTP
 *  > stacks they could resolve to different addresses (v4 vs v6) and the media
 *  > fetch would come back 403.
 *
 * (An earlier version ran a client of its own, on the theory that URLSession has
 * a different TLS fingerprint from Ktor's Darwin engine. That was a symptom of
 * the split, not a cause of it — and with one client there is no longer a second
 * fingerprint to differ.)
 *
 * Upstream's ExoPlayer starts as soon as the first bounded range arrives, and
 * [streamToFile] matches that: the first chunk is on disk and [ready] fires so
 * the engine can play while later chunks keep appending.
 */
object StreamDownloadBridge {

    private val bridgeScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val jobsLock = NSLock()
    private val downloadJobs = mutableMapOf<String, Job>()

    fun interface DownloadCallback {
        fun onResult(path: String?, message: String?)
    }
    fun interface ProgressCallback {
        fun onProgress(received: Long, total: Long)
    }

    fun downloadWithProgress(downloadId: String, url: String, headers: Map<String, String>, progress: ProgressCallback, callback: DownloadCallback) {
        startStream(downloadId, url, headers, ready = DownloadCallback { _, _ -> }, done = callback, progress = progress)
    }

    /** Wait for the whole file, then [callback]. Prefetch / cache path. */
    fun download(downloadId: String, url: String, headers: Map<String, String>, callback: DownloadCallback) {
        startStream(downloadId, url, headers, ready = DownloadCallback { _, _ -> }, done = callback)
    }

    /** Stops the active network/file job for one download, if it has started. */
    fun cancel(downloadId: String) {
        jobsLock.lock()
        val job = downloadJobs.remove(downloadId)
        jobsLock.unlock()
        job?.cancel()
    }

    /**
     * Progressive fetch. [ready] fires once the first chunk is on disk, so play can
     * start; [done] fires when the last chunk is written, or on error.
     *
     * The chunk size is [PlayerClient.rangeBytesFor] — the most this URL's own
     * client will serve in one range, and deliberately the same figure
     * [Http.probe] asks for. A probe smaller than the real fetch cannot see a
     * refusal the real fetch would meet, which is what "it loads and then doesn't
     * play" is made of.
     *
     * It was a fixed 2 MiB, which was wrong in both directions. Against most
     * clients that is twice what they will serve in one range, so every chunk
     * past the first was asking for a refusal; and against `ANDROID_VR` and
     * `TVHTML5_SIMPLY` — which cap at half a megabyte — it was asking for four
     * times too much, so a working client produced a track that died one megabyte
     * in. The figure is a property of the URL's client, not a constant.
     *
     * A 403 on a chunk is reported to [StreamResolver.onPlaybackRefused] rather
     * than retried blindly. Retrying the same URL against the same client is how a
     * session talks itself into being throttled, and the resolver already knows how
     * to forget the URL and stand the client down — which is the response that
     * actually changes the next attempt.
     */
    fun streamToFile(
        url: String,
        headers: Map<String, String>,
        ready: DownloadCallback,
        done: DownloadCallback,
    ) {
        DirectStreamDownload.create(bridgeScope, url, headers, ready, done).start()
    }

    fun streamSourceRequest(requestId: String, url: String, headers: Map<String, String>, ready: DownloadCallback, done: DownloadCallback) {
        val job = DirectStreamDownload.create(bridgeScope, url, headers, ready, done)
        register(requestId, job)
        job.start()
    }

    fun streamTrackRequest(requestId: String, videoId: String, maxKbps: Int, url: String, headers: Map<String, String>,
                           expectedMimeType: String?, firstRangeRetry: Int, ready: DownloadCallback, done: DownloadCallback) {
        startStream(requestId, url, headers, ready, done, videoId, maxKbps, expectedMimeType, firstRangeRetry)
    }

    private fun register(id: String, job: Job) {
        jobsLock.lock(); downloadJobs[id] = job; jobsLock.unlock()
        job.invokeOnCompletion {
            jobsLock.lock()
            if (downloadJobs[id] === job) downloadJobs.remove(id)
            jobsLock.unlock()
        }
    }

    /**
     * [streamToFile] for a YouTube track, which lets a refusal *mid-track* be
     * answered with a fresh URL for the same rendition, resumed at the same byte.
     * Without the id the bridge can only give up, and the listener hears the song
     * stop part-way through.
     */
    fun streamTrackToFile(
        videoId: String,
        maxKbps: Int,
        url: String,
        headers: Map<String, String>,
        expectedMimeType: String?,
        firstRangeRetry: Int,
        ready: DownloadCallback,
        done: DownloadCallback,
    ) {
        startStream(null, url, headers, ready, done, videoId = videoId, maxKbps = maxKbps,
            expectedMimeType = expectedMimeType, firstRangeRetry = firstRangeRetry)
    }

    /**
     * The device's network path changed (Wi-Fi ↔ cellular, VPN up, captive portal
     * cleared). A request in flight on the old interface would otherwise sit out
     * its whole timeout before failing; every active stream drops it and asks again
     * at the same offset, and any stream waiting out a backoff retries now.
     */
    fun networkChanged() {
        networkGeneration.value = networkGeneration.value + 1
        DebugLog.d("network path changed; active streams will re-request at their offsets")
    }

    private val networkGeneration = MutableStateFlow(0L)
    private val networkAvailable = MutableStateFlow(true)
    internal suspend fun awaitConnectivity() { networkAvailable.first { it } }

    fun networkStatus(available: Boolean) {
        if (networkAvailable.value != available) {
            networkAvailable.value = available
            networkChanged()
        }
    }

    private class NetworkChanged : Exception("network path changed")

    /**
     * One range, abandoned early if the network path changes underneath it.
     * Returns null when it was abandoned for that reason.
     */
    private suspend fun fetchRange(url: String, headers: Map<String, String>, maxBytes: Int): RawHttpBytes? {
        val startGeneration = networkGeneration.value
        return coroutineScope {
            val fetch = async { Http.getBytesRaw(url, headers, maxBytes, CHUNK_TIMEOUT_MS) }
            val watcher = launch {
                networkGeneration.first { it != startGeneration }
                fetch.cancel(CancellationException("network changed"))
            }
            try {
                fetch.await()
            } catch (e: CancellationException) {
                currentCoroutineContext().ensureActive()
                null
            } finally {
                watcher.cancel()
            }
        }
    }

    /** One bounded opening request; its response is the validation and audio read. */
    private suspend fun fetchFirstRange(url: String, headers: Map<String, String>): RawHttpBytes? {
        val startGeneration = networkGeneration.value
        return coroutineScope {
            val fetch = async { Http.getBytesRaw(url, headers, FIRST_RANGE_BYTES.toInt(), CHUNK_TIMEOUT_MS) }
            val watcher = launch {
                networkGeneration.first { it != startGeneration }
                fetch.cancel(CancellationException("network changed"))
            }
            try {
                fetch.await()
            } catch (e: CancellationException) {
                currentCoroutineContext().ensureActive()
                null
            } finally {
                watcher.cancel()
            }
        }
    }

    /** Sleep [millis], or less if the network path changes first. */
    private suspend fun backoff(millis: Long) {
        val startGeneration = networkGeneration.value
        withTimeoutOrNull(millis) { networkGeneration.first { it != startGeneration } }
    }

    @OptIn(ExperimentalForeignApi::class)
    private fun startStream(
        downloadId: String?,
        url: String,
        headers: Map<String, String>,
        ready: DownloadCallback,
        done: DownloadCallback,
        videoId: String? = null,
        maxKbps: Int = Int.MAX_VALUE,
        expectedMimeType: String? = null,
        firstRangeRetry: Int = 0,
        progress: ProgressCallback? = null,
    ) {
        val job = bridgeScope.launch(start = CoroutineStart.LAZY) {
            var tmpPath: String? = null
            var file: CPointer<FILE>? = null
            try {
                DebugLog.d("stream starting: ${url.take(120)}")

                var currentUrl = url
                var currentHeaders = headers
                val chunkSize = minOf(PlayerClient.rangeBytesFor(url), 1024L * 1024)
                var declaredLength = PlayerClient.lengthFromUrl(url)
                check(declaredLength == null || declaredLength in 1..MAX_BYTES) { "Invalid audio download size" }
                val tmpDir = NSTemporaryDirectory()
                val ext = when {
                    url.contains("mime=video", ignoreCase = true) ||
                        url.contains("itag=18") -> "mp4"
                    else -> "m4a"
                }
                val path = "$tmpDir/bitchord-${NSUUID().UUIDString}.$ext"
                tmpPath = path

                // Upstream reads the total out of the URL's own `clen` rather than
                // making a request to find out, so read-ahead knows when it is done.
                declaredLength?.let { clen ->
                    val lenPath = "$path.len"
                    val digits = clen.toString().encodeToByteArray()
                    val lenFile = fopen(lenPath, "wb")
                    if (lenFile != null) {
                        digits.usePinned { pinned ->
                            fwrite(
                                pinned.addressOf(0),
                                1.convert(),
                                digits.size.convert(),
                                lenFile,
                            )
                        }
                        fclose(lenFile)
                    }
                }
                NSMutableData().writeToFile("$path.grow", atomically = true)

                var offset = 0L
                var consecutiveEmpty = 0
                var readyFired = false
                var failures = 0
                var remints = 0

                while (true) {
                    networkAvailable.first { it }
                    currentCoroutineContext().ensureActive()
                    // The first range is small so the decoder has its header and
                    // first frames in a fraction of the time a full range takes;
                    // first sound waits on this one request and nothing else.
                    val want = minOf(if (offset == 0L) minOf(FIRST_RANGE_BYTES, chunkSize) else chunkSize,
                        declaredLength?.let { it - offset } ?: chunkSize)
                    check(want > 0) { "Invalid audio range offset" }
                    val rangeEnd = offset + want - 1
                    val rangeHeaders = currentHeaders + ("Range" to "bytes=$offset-$rangeEnd")

                    val data = try {
                        if (offset == 0L) {
                            val response = fetchFirstRange(currentUrl, rangeHeaders) ?: throw NetworkChanged()
                            if (response.status in REFUSAL_CODES) throw HttpStatusException(response.status)
                            if (response.status !in 200..299) throw HttpStatusException(response.status)
                            val bytes = validateFirstMediaRange(response, expectedMimeType)
                            declaredLength = validateAppendedRange(response, offset, want, declaredLength)
                            bytes
                        } else {
                            val response = fetchRange(currentUrl, rangeHeaders, want.toInt() + 1) ?: throw NetworkChanged()
                            declaredLength = validateAppendedRange(response, offset, want, declaredLength)
                            response.body!!
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        val code = httpCodeOf(e)
                        if (offset == 0L && !readyFired && videoId != null &&
                            (e is InvalidFirstMediaRangeException || (code != null && code in REFUSAL_CODES))) {
                            val status = (e as? InvalidFirstMediaRangeException)?.responseCode ?: code ?: 0
                            // The client that minted a refused URL is set aside at
                            // once, as upstream does: asking it again spent one of
                            // the few attempts on the answer it had just given.
                            StreamResolver.onFirstRangeRejected(currentUrl, status, excludeClient = true)
                            throw e
                        }
                        if (e is InvalidFirstMediaRangeException) throw e
                        if (e is InvalidMediaRangeException) throw e
                        if (!networkAvailable.value || e is NetworkChanged) continue
                        if (code != null && code in REFUSAL_CODES) {
                            DebugLog.w("stream refused with $code at offset $offset")
                            StreamResolver.onPlaybackRefused(currentUrl, code)
                            // Before the first byte the host re-resolves on its own.
                            // Mid-track it cannot without restarting the song, so
                            // the bridge asks for the same rendition and resumes.
                            val fresh = if (readyFired && videoId != null && remints < MAX_REMINTS) {
                                remints++
                                runCatching { StreamResolver.resolve(videoId, maxKbps) }.getOrNull()
                                    ?.takeIf { sameRendition(currentUrl, it.url) }
                            } else null
                            if (fresh == null) throw e
                            DebugLog.d("stream re-minted at offset $offset; resuming on a fresh URL")
                            currentUrl = fresh.url
                            currentHeaders = fresh.headers
                            continue
                        }
                        // Transport trouble (and 5xx/429): the URL is still good,
                        // so ask again for the same bytes rather than ending here.
                        failures++
                        if (failures > MAX_TRANSPORT_RETRIES) {
                            DebugLog.w("stream chunk failed at offset $offset after $failures tries: ${e.message}")
                            throw e
                        }
                        val wait = BACKOFF_MS[minOf(failures - 1, BACKOFF_MS.lastIndex)]
                        DebugLog.d("stream chunk failed at offset $offset (${e.message}); retry $failures in ${wait}ms")
                        if (e !is NetworkChanged) backoff(wait)
                        continue
                    }
                    currentCoroutineContext().ensureActive()
                    failures = 0

                    if (data.isEmpty()) {
                        consecutiveEmpty++
                        DebugLog.d("stream returned an empty chunk ($consecutiveEmpty), stopping")
                        if (consecutiveEmpty >= 2) error("Audio ended before its declared length")
                        continue
                    }
                    consecutiveEmpty = 0

                    if (file == null) {
                        file = fopen(path, "wb")
                            ?: throw IllegalStateException("open $path failed")
                    }
                    data.usePinned { pinned ->
                        val written = fwrite(
                            pinned.addressOf(0),
                            1.convert(),
                            data.size.convert(),
                            file,
                        )
                        if (written.toLong() != data.size.toLong()) {
                            throw IllegalStateException("short write at offset $offset")
                        }
                    }
                    fflush(file)
                    offset += data.size
                    progress?.onProgress(offset, declaredLength ?: 0)

                    if (!readyFired) {
                        currentCoroutineContext().ensureActive()
                        readyFired = true
                        DebugLog.d("first chunk ready: $path ($offset bytes)")
                        ready.onResult(path, null)
                    }

                    // With a declared length that is the end; a short range before
                    // it is a connection that gave up early, not the end of the file.
                    if (declaredLength != null) {
                        if (offset >= declaredLength) break
                    } else if (data.size < want) break
                    check(offset <= MAX_BYTES) { "Audio exceeds the download size limit" }
                }

                file?.let { fflush(it); fclose(it) }
                file = null

                if (!readyFired) {
                    currentCoroutineContext().ensureActive()
                    done.onResult(null, "Download returned no bytes")
                    return@launch
                }

                currentCoroutineContext().ensureActive()
                check(declaredLength == null || offset == declaredLength) { "Incomplete audio download" }
                NSMutableData().writeToFile("$path.complete", atomically = true)
                DebugLog.d("stream complete: $path ($offset bytes)")
                currentCoroutineContext().ensureActive()
                done.onResult(path, null)
            } catch (e: CancellationException) {
                // A cancelled row must not leave a partial file that could be
                // mistaken for a completed download or resumed by the player.
                tmpPath?.let { path ->
                    listOf(path, "$path.len", "$path.grow", "$path.complete", "$path.failed").forEach {
                        NSFileManager.defaultManager.removeItemAtPath(it, null)
                    }
                }
                done.onResult(null, "Download cancelled")
            } catch (e: Throwable) {
                currentCoroutineContext().ensureActive()
                DebugLog.e("stream failed", e)
                // `.failed` before `.complete`: the reader stops waiting either way,
                // but a failed file ends in an error the player can recover from
                // rather than a short track that looks like it finished.
                tmpPath?.let {
                    NSMutableData().writeToFile("$it.failed", atomically = true)
                    NSMutableData().writeToFile("$it.complete", atomically = true)
                }
                // A refusal and a transport failure call for opposite responses
                // at the call site: one means "this URL is dead, go and get another",
                // the other means "that attempt failed, here is the same URL to try
                // with better networking". Tagging it here, rather than leaving the
                // host to read the message, is the point of [isRefusal].
                val code = httpCodeOf(e)
                val detail = when (e) {
                    is InvalidFirstMediaRangeException -> "$INVALID_FIRST_RANGE_PREFIX${e.message ?: "media rejected"}"
                    else -> e.message ?: e.toString()
                }
                done.onResult(
                    null,
                    if (code != null && code in REFUSAL_CODES) "$REFUSED_PREFIX$code $detail"
                    else detail,
                )
            } finally {
                file?.let { fclose(it) }
            }
        }
        if (downloadId != null) {
            jobsLock.lock()
            downloadJobs[downloadId] = job
            jobsLock.unlock()
            job.invokeOnCompletion {
                jobsLock.lock()
                if (downloadJobs[downloadId] === job) downloadJobs.remove(downloadId)
                jobsLock.unlock()
            }
        }
        job.start()
    }

    /** Same itag and same byte length: a byte offset in one is valid in the other. */
    private fun sameRendition(old: String, new: String): Boolean {
        val oldLen = PlayerClient.lengthFromUrl(old) ?: return false
        return oldLen == PlayerClient.lengthFromUrl(new) && itagOf(old) != null && itagOf(old) == itagOf(new)
    }

    private fun itagOf(url: String): String? =
        Regex("[?&]itag=(\\d+)").find(url)?.groupValues?.get(1)

    /** The status code out of [Http]'s refusal message, if it was a refusal. */
    private fun httpCodeOf(e: Throwable): Int? =
        e.message?.let { message ->
            Regex("HTTP (\\d{3})").find(message)?.groupValues?.get(1)?.toIntOrNull()
        }


    /**
     * Whether a [DownloadCallback] message means the server *refused* the range,
     * rather than the attempt failing for some other reason.
     *
     * Asked by the host rather than answered by pattern-matching the message over
     * there: the tag and the question belong to whoever produces the message, so
     * the two cannot drift.
     */
    fun isRefusal(message: String?): Boolean = message?.startsWith(REFUSED_PREFIX) == true

    fun isInvalidFirstRange(message: String?): Boolean = message?.startsWith(INVALID_FIRST_RANGE_PREFIX) == true

    /** The status code a refusal carried, when [isRefusal]. */
    fun refusalCode(message: String?): Int? =
        if (message == null || !isRefusal(message)) null
        else message.removePrefix(REFUSED_PREFIX).takeWhile { it.isDigit() }.toIntOrNull()

    private const val REFUSED_PREFIX = "refused: "
    private const val INVALID_FIRST_RANGE_PREFIX = "invalid first range: "
    private val REFUSAL_CODES = setOf(403, 404, 410)


    /** A ceiling so a URL that never stops returning data cannot fill the disk. */
    private const val MAX_BYTES = 200L * 1024 * 1024

    /** The opening range: enough for the container header and the first frames. */
    private const val FIRST_RANGE_BYTES = 128L * 1024

    /** Per range. A full range is a megabyte; one that takes this long is stuck. */
    private const val CHUNK_TIMEOUT_MS = 15_000L

    /** Roughly 45 s of trying, inside the reader's two-minute patience. */
    private const val MAX_TRANSPORT_RETRIES = 8
    private val BACKOFF_MS = longArrayOf(250, 500, 1_000, 2_000, 4_000, 8_000, 8_000, 8_000)

    /** Fresh URLs one track may ask for mid-stream before giving up. */
    private const val MAX_REMINTS = 2
}
