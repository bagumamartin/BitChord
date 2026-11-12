package com.music.bitchord.data.innertube

import kotlinx.coroutines.test.runTest
import kotlin.test.*

/** The anonymous visionOS request that is asked before the extraction stack. */
class CleanVisionClientTest {
    private val media = "https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&itag="

    private fun response(status: String = "OK", formats: String) = """
        {"playabilityStatus":{"status":"$status"},
         "videoDetails":{"lengthSeconds":"215"},
         "playerConfig":{"audioConfig":{"loudnessDb":-3.5}},
         "streamingData":{"adaptiveFormats":[$formats]}}
    """.trimIndent()

    private fun format(itag: Int, mime: String, bitrate: Int, url: String?) =
        """{"itag":$itag,"mimeType":"$mime","bitrate":$bitrate""" + (url?.let { ""","url":"$it"""" } ?: "") + "}"

    private suspend fun fixture(body: suspend () -> Unit) {
        val mint = CleanVisionClient.mintVisitor
        val transport = CleanVisionClient.transport
        try {
            CleanVisionClient.forgetVisitor()
            body()
        } finally {
            CleanVisionClient.mintVisitor = mint
            CleanVisionClient.transport = transport
            CleanVisionClient.forgetVisitor()
        }
    }

    @Test fun servesThePlainAudioUrlAndKeepsItsVisitorWhileItWorks() = runTest {
        fixture {
            var minted = 0
            val asked = mutableListOf<String>()
            CleanVisionClient.mintVisitor = { "visitor-${++minted}" }
            CleanVisionClient.transport = { body, visitor ->
                asked += visitor
                assertContains(body, "\"clientName\":\"VISIONOS\"")
                assertContains(body, "\"visitorData\":\"$visitor\"")
                response(formats = listOf(
                    format(140, "audio/mp4; codecs=\\\"mp4a.40.2\\\"", 130_000, media + "140"),
                    format(251, "audio/webm; codecs=\\\"opus\\\"", 150_000, media + "251"),
                    format(137, "video/mp4; codecs=\\\"avc1\\\"", 4_000_000, media + "137"),
                ).joinToString(","))
            }
            val first = CleanVisionClient.resolve("track", Int.MAX_VALUE)
            val stream = assertIs<CleanVisionClient.Outcome.Served>(first).stream
            assertTrue(stream.mimeType.startsWith("audio/"))
            assertTrue(stream.url.startsWith(media))
            assertEquals(CleanVisionClient.PROFILE, stream.clientName)
            assertEquals(emptyMap(), stream.headers)
            assertEquals(215L, stream.durationSeconds)
            assertEquals(-3.5, stream.loudnessDb)
            assertIs<CleanVisionClient.Outcome.Served>(CleanVisionClient.resolve("other", Int.MAX_VALUE))
            assertEquals(listOf("visitor-1", "visitor-1"), asked)
            assertNull(CleanVisionClient.declinedReason("track"))
        }
    }

    @Test fun aRefusalIsReportedAndItsVisitorIsNeverAskedAgain() = runTest {
        fixture {
            var minted = 0
            val asked = mutableListOf<String>()
            CleanVisionClient.mintVisitor = { "visitor-${++minted}" }
            CleanVisionClient.transport = { _, visitor ->
                asked += visitor
                response(status = "LOGIN_REQUIRED", formats = "")
            }
            val declined = assertIs<CleanVisionClient.Outcome.Declined>(CleanVisionClient.resolve("track", Int.MAX_VALUE))
            assertEquals("playability:LOGIN_REQUIRED", declined.reason)
            assertEquals("playability:LOGIN_REQUIRED", CleanVisionClient.declinedReason("track"))
            assertNull(CleanVisionClient.declinedReason("other"))
            CleanVisionClient.resolve("track", Int.MAX_VALUE)
            assertEquals(listOf("visitor-1", "visitor-2"), asked)
        }
    }

    @Test fun urlsThatAreNotReadyToFetchAreLeftToTheExtractor() = runTest {
        fixture {
            CleanVisionClient.mintVisitor = { "visitor" }
            val candidates = listOf(
                format(251, "audio/webm; codecs=\\\"opus\\\"", 150_000, null),
                format(140, "audio/mp4; codecs=\\\"mp4a.40.2\\\"", 130_000, media + "140&n=abcdef"),
                format(139, "audio/mp4; codecs=\\\"mp4a.40.5\\\"", 50_000, "https://media.example.invalid/videoplayback?itag=139"),
            ).joinToString(",")
            CleanVisionClient.transport = { _, _ -> response(formats = candidates) }
            val declined = assertIs<CleanVisionClient.Outcome.Declined>(CleanVisionClient.resolve("track", Int.MAX_VALUE))
            assertEquals("formats:no_ready_audio_url", declined.reason)
        }
    }

    @Test fun aFailedRequestOrMissingVisitorDeclinesWithoutThrowing() = runTest {
        fixture {
            CleanVisionClient.mintVisitor = { null }
            CleanVisionClient.transport = { _, _ -> fail("asked without a visitor") }
            assertEquals(CleanVisionClient.Outcome.Declined("visitor_unavailable"),
                CleanVisionClient.resolve("track", Int.MAX_VALUE))
            CleanVisionClient.mintVisitor = { "visitor" }
            CleanVisionClient.transport = { _, _ -> throw IllegalStateException("offline") }
            assertEquals(CleanVisionClient.Outcome.Declined("request:IllegalStateException"),
                CleanVisionClient.resolve("track", Int.MAX_VALUE))
        }
    }

    @Test fun theReportNamesTheCleanClientAheadOfTheExtractorsOwn() {
        assertEquals(
            PlayerBridge.CLIENTS_MARKER + " VISIONOS_CLEAN=playability:LOGIN_REQUIRED",
            PlayerBridge.clientOutcomes(IllegalStateException("x"), "playability:LOGIN_REQUIRED"),
        )
        assertEquals("", PlayerBridge.clientOutcomes(IllegalStateException("x"), null))
    }
}
