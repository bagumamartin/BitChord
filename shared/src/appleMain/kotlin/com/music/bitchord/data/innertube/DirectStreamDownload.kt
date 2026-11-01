package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.Http
import com.music.bitchord.data.http.HttpStatusException
import io.ktor.client.plugins.timeout
import io.ktor.client.request.header
import io.ktor.client.request.prepareGet
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpHeaders
import io.ktor.utils.io.readAvailable
import io.ktor.utils.io.readRemaining
import kotlinx.io.readByteArray
import kotlinx.cinterop.*
import kotlinx.coroutines.*
import platform.Foundation.*
import platform.posix.*

/** One streaming GET for ordinary audio, with bounded RAM and validated resume.
 * A full 200 response is normal here; YouTube's bounded-range rules are separate.
 */
@OptIn(ExperimentalForeignApi::class)
internal object DirectStreamDownload {
    fun create(scope: CoroutineScope, url: String, headers: Map<String, String>,
               ready: StreamDownloadBridge.DownloadCallback, done: StreamDownloadBridge.DownloadCallback): Job =
        scope.launch(start = CoroutineStart.LAZY) {
            var path: String? = null
            var output: CPointer<FILE>? = null
            var offset = 0L
            var total: Long? = null
            var validator: String? = null
            var failures = 0
            var announced = false
            try {
                while (true) {
                    StreamDownloadBridge.awaitConnectivity()
                    try {
                        Http.client.prepareGet(url) {
                            headers.forEach { (key, value) -> header(key, value) }
                            if (offset > 0) {
                                check(validator != null) { "Source cannot safely resume without a validator" }
                                header(HttpHeaders.Range, "bytes=$offset-")
                                header(HttpHeaders.IfRange, validator!!)
                            }
                            timeout { requestTimeoutMillis = 15 * 60_000; connectTimeoutMillis = 20_000; socketTimeoutMillis = 30_000 }
                        }.execute { response ->
                            val code = response.status.value
                            if (code !in 200..299) throw HttpStatusException(code)
                            val length = response.headers[HttpHeaders.ContentLength]?.toLongOrNull()
                            if (offset > 0) {
                                val range = response.headers[HttpHeaders.ContentRange]
                                    ?.let { Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(it) }
                                check(code == 206 && range != null && range.groupValues[1].toLong() == offset &&
                                    (total == null || range.groupValues[3].toLong() == total)) { "Source changed or ignored the resume range" }
                                val currentValidator = response.headers[HttpHeaders.ETag]?.takeUnless { it.startsWith("W/") }
                                    ?: response.headers[HttpHeaders.LastModified]
                                check(currentValidator == validator) { "Source changed while resuming" }
                            } else {
                                check(code == 200) { "Source did not return a complete recording" }
                                total = length
                                validator = response.headers[HttpHeaders.ETag]?.takeUnless { it.startsWith("W/") }
                                    ?: response.headers[HttpHeaders.LastModified]
                            }
                            check(total == null || total!! <= 1024L * 1024 * 1024) { "Audio exceeds the cache size limit" }
                            val channel = response.bodyAsChannel()
                            val head = channel.readRemaining(4096).readByteArray()
                            check(head.isNotEmpty()) { "Source returned no audio" }
                            if (path == null) {
                                val ext = containerExtension(head) ?: error("Source returned a playlist or unsupported audio")
                                path = "${NSTemporaryDirectory()}/bitchord-${NSUUID().UUIDString}.$ext"
                                NSMutableData().writeToFile("$path.grow", atomically = true)
                                total?.let { length ->
                                    val lengthFile = fopen("$path.len", "wb")
                                    if (lengthFile != null) {
                                        val digits = length.toString().encodeToByteArray()
                                        digits.usePinned { fwrite(it.addressOf(0), 1.convert(), digits.size.convert(), lengthFile) }
                                        fclose(lengthFile)
                                    }
                                }
                                output = fopen(path!!, "wb") ?: error("Cannot create audio cache file")
                            }
                            fun append(bytes: ByteArray, count: Int) {
                                bytes.usePinned { pinned ->
                                    check(fwrite(pinned.addressOf(0), 1.convert(), count.convert(), output).toLong() == count.toLong()) { "Short audio write" }
                                }
                                fflush(output)
                                offset += count
                                check(offset <= 1024L * 1024 * 1024 && (total == null || offset <= total!!)) { "Audio exceeded its declared size" }
                            }
                            append(head, head.size)
                            if (!announced) { announced = true; ready.onResult(path, null) }
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                currentCoroutineContext().ensureActive()
                                val read = channel.readAvailable(buffer, 0, buffer.size)
                                if (read < 0) break
                                if (read > 0) { append(buffer, read); failures = 0 }
                            }
                            if (total != null && offset != total) throw Exception("Source ended before its declared length")
                        }
                        break
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Throwable) {
                        if ((failure is IllegalStateException && failure !is HttpStatusException) ||
                            (failure is HttpStatusException && failure.status in 400..499 && failure.status != 429) || ++failures > 8) throw failure
                        StreamDownloadBridge.awaitConnectivity()
                        delay(minOf(8000L, 250L shl minOf(failures - 1, 5)))
                    }
                }
                output?.let { fclose(it) }; output = null
                currentCoroutineContext().ensureActive()
                check(announced && offset > 0) { "Source returned no audio" }
                NSMutableData().writeToFile("$path.complete", atomically = true)
                done.onResult(path, null)
            } catch (failure: Throwable) {
                path?.let {
                    NSMutableData().writeToFile("$it.failed", atomically = true)
                    NSMutableData().writeToFile("$it.complete", atomically = true)
                }
                done.onResult(null, failure.message ?: "Source transfer failed")
            } finally { output?.let { fclose(it) } }
        }

    private fun containerExtension(bytes: ByteArray): String? {
        fun ascii(start: Int, end: Int) = if (bytes.size >= end) bytes.copyOfRange(start, end).decodeToString() else ""
        return when {
            ascii(0, 4) == "fLaC" -> "flac"
            ascii(0, 4) == "RIFF" && ascii(8, 12) == "WAVE" -> "wav"
            ascii(0, 4) == "FORM" && ascii(8, 12) in listOf("AIFF", "AIFC") -> "aiff"
            ascii(4, 8) == "ftyp" -> "m4a"
            ascii(0, 4) == "OggS" -> "ogg"
            bytes.size >= 4 && bytes[0] == 0x1A.toByte() && bytes[1] == 0x45.toByte() && bytes[2] == 0xDF.toByte() && bytes[3] == 0xA3.toByte() -> "webm"
            ascii(0, 3) == "ID3" -> "mp3"
            bytes.size >= 2 && bytes[0] == 0xFF.toByte() && (bytes[1].toInt() and 0xF6) == 0xF0 -> "aac"
            bytes.size >= 2 && bytes[0] == 0xFF.toByte() && (bytes[1].toInt() and 0xE0) == 0xE0 -> "mp3"
            else -> null
        }
    }
}
