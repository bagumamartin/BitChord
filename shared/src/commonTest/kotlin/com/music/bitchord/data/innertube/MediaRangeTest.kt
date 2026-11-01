package com.music.bitchord.data.innertube

import com.music.bitchord.data.http.RawHttpBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails

class MediaRangeTest {
    @Test fun contiguousRangesKeepTheSameIdentity() {
        assertEquals(12L, validateAppendedRange(RawHttpBytes(206, ByteArray(8), "audio/mp4", contentRange = "bytes 0-7/12"), 0, 8, null))
        assertEquals(12L, validateAppendedRange(RawHttpBytes(206, ByteArray(4), "audio/mp4", contentRange = "bytes 8-11/12"), 8, 8, 12))
    }
    @Test fun aShortValidRangeCanContinueAtItsActualEnd() {
        assertEquals(100L, validateAppendedRange(RawHttpBytes(206, ByteArray(3), "audio/mp4", contentRange = "bytes 20-22/100"), 20, 8, 100))
    }
    @Test fun ignoredRangesChangedRecordingsAndTruncationAreRejected() {
        for (response in listOf(
            RawHttpBytes(200, ByteArray(8), "audio/mp4"),
            RawHttpBytes(206, ByteArray(8), "audio/mp4", contentRange = "bytes 0-7/100"),
            RawHttpBytes(206, ByteArray(8), "audio/mp4", contentRange = "bytes 20-27/101"),
            RawHttpBytes(206, ByteArray(3), "audio/mp4", contentRange = "bytes 20-27/100"),
            RawHttpBytes(206, ByteArray(9), "audio/mp4", contentRange = "bytes 20-28/100"),
            RawHttpBytes(206, ByteArray(0), "audio/mp4", contentRange = "bytes 20-19/100"),
            RawHttpBytes(206, ByteArray(8), "text/html", contentRange = "bytes 20-27/100"),
        )) assertFails { validateAppendedRange(response, 20, 8, 100) }
    }
    @Test fun unknownLengthCannotBeGuessedFromAShortBody() {
        assertFails { validateAppendedRange(RawHttpBytes(206, ByteArray(4)), 0, 8, null) }
        assertFails { validateAppendedRange(RawHttpBytes(206, ByteArray(4), contentRange = "nonsense"), 0, 8, 100) }
    }
}
