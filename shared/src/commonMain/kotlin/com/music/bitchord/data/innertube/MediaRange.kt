package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.HttpStatusException
import com.music.bitchord.data.http.RawHttpBytes

/** A response must describe the exact bytes being appended, never a full 200 body. */
internal fun validateAppendedRange(response: RawHttpBytes, offset: Long, wanted: Long, knownTotal: Long?): Long? {
    fun requireRange(condition: Boolean, message: () -> String) { if (!condition) throw InvalidMediaRangeException(message()) }
    if (response.status !in 200..299) throw HttpStatusException(response.status)
    requireRange(response.status == 206) { "Server ignored the audio range at $offset" }
    val body = response.body ?: error("Audio range returned no data")
    requireRange(body.isNotEmpty() && body.size.toLong() <= wanted) { "Invalid audio range length at $offset" }
    requireRange(com.music.bitchord.data.http.ProbeResult(response.status, response.contentType, true).classify() == ProbeVerdict.OK) { "Audio range returned an error document" }
    val range = response.contentRange?.let { Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(it.trim()) }
    val total = range?.groupValues?.get(3)?.toLongOrNull() ?: knownTotal
    if (range != null) {
        val start = range.groupValues[1].toLong()
        val end = range.groupValues[2].toLong()
        requireRange(start == offset && end >= start && end - start + 1 == body.size.toLong() && total != null && end < total) {
            "Mismatched audio Content-Range at $offset"
        }
        requireRange(knownTotal == null || total == knownTotal) { "Audio length changed mid-transfer" }
    } else {
        requireRange(response.contentRange == null && knownTotal != null) { "Missing audio byte-range identity" }
    }
    requireRange(total == null || offset + body.size <= total) { "Audio range exceeds the recording length" }
    return total
}
internal class InvalidMediaRangeException(message: String) : Exception(message)
