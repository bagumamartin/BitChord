package com.music.bitchord.data.innertube

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import com.music.bitchord.data.http.RawHttpBytes
import kotlin.test.*

/** The production resolver shell around upstream extraction, with synthetic media. */
class StreamResolverRecoveryTest {
    private suspend fun fixture(body: suspend () -> Unit) {
        val extract = StreamResolver.extraction
        val rebuild = StreamResolver.rebuild
        try {
            StreamResolver.rebuild = {}
            Innertube.cookie = null
            StreamResolver.onSessionChanged()
            body()
        } finally {
            StreamResolver.extraction = extract
            StreamResolver.rebuild = rebuild
            Innertube.cookie = null; StreamResolver.onSessionChanged()
        }
    }
    private fun stream(id: String) = StreamResolver.ResolvedStream(
        "https://media.invalid/$id", 128, "audio/mp4", mapOf("User-Agent" to "synthetic-profile"))

    @Test fun openingRangeMustBePartialMediaAndCannotAcceptTruncatedFullBody() {
        val bytes = ByteArray(MIN_FIRST_RANGE_BYTES) { 7 }
        assertContentEquals(bytes, validateFirstMediaRange(RawHttpBytes(206, bytes, "audio/mp4")))
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(403, bytes, "text/html"))
        }
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(206, bytes, "text/html"))
        }
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(206, bytes, "application/json"))
        }
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(206, bytes, "video/mp4"), "audio/mp4")
        }
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(206, null, "audio/mp4"))
        }
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(206, ByteArray(0), "audio/mp4"))
        }
        assertFailsWith<InvalidFirstMediaRangeException> {
            validateFirstMediaRange(RawHttpBytes(206, ByteArray(1_024), "audio/mp4"))
        }
    }

    @Test fun aFailedTrackIsAskedForAgainOnlyOnARebuiltSessionAndRebuildsAreSpaced() = runTest {
        fixture {
            Innertube.cookie = "SAPISID=synthetic"
            var attempts = 0; var rebuilds = 0
            StreamResolver.extraction = { _, _ -> attempts++; throw IllegalStateException("refused") }
            StreamResolver.rebuild = { rebuilds++ }
            repeat(3) { assertFailsWith<IllegalStateException> { StreamResolver.resolve("track") } }
            assertEquals(1, attempts)
            StreamResolver.rebuildSession("track")
            repeat(3) { assertFailsWith<IllegalStateException> { StreamResolver.resolve("track") } }
            assertEquals(2, attempts)
            StreamResolver.rebuildSession("track")
            assertFailsWith<IllegalStateException> { StreamResolver.resolve("track") }
            assertEquals(2, attempts)
            assertEquals(1, rebuilds)
            // Another track is its own question.
            assertFailsWith<IllegalStateException> { StreamResolver.resolve("other") }
            assertEquals(3, attempts)
        }
    }

    @Test fun resolutionReturnsUrlWithoutASeparateMediaProbe() = runTest {
        fixture {
            var attempts = 0
            StreamResolver.extraction = { _, _ -> attempts++; stream("direct") }
            val first = StreamResolver.resolve("track")!!
            val cached = StreamResolver.resolve("track")!!
            assertEquals("https://media.invalid/direct", first.url)
            assertEquals(first, cached)
            assertEquals(1, attempts)
        }
    }
    @Test fun distinctTracksResolveIndependently() = runTest {
        fixture {
            var attempts = 0
            StreamResolver.extraction = { id, _ -> attempts++; stream(id) }
            assertNotNull(StreamResolver.resolve("bad"))
            assertEquals(1, attempts)
            assertNotNull(StreamResolver.resolve("good"))
            assertEquals(2, attempts)
        }
    }
    @Test fun duplicateRequestsShareOneExtraction() = runTest {
        fixture {
            var requests = 0
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            StreamResolver.extraction = { id, _ -> requests++; entered.complete(Unit); release.await(); stream(id) }
            val first = async { StreamResolver.resolve("shared") }
            entered.await()
            val second = async { StreamResolver.resolve("shared") }
            yield(); release.complete(Unit)
            assertEquals(first.await(), second.await()); assertEquals(1, requests)
        }
    }
    @Test fun cancellingOneListenerDoesNotCancelAnother() = runTest {
        fixture {
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            StreamResolver.extraction = { id, _ -> entered.complete(Unit); release.await(); stream(id) }
            val first = async { StreamResolver.resolve("shared") }; entered.await()
            val second = async { StreamResolver.resolve("shared") }; yield()
            first.cancelAndJoin(); release.complete(Unit)
            assertNotNull(second.await())
        }
    }
    @Test fun abandonedSelectionCancelsItsExtraction() = runTest {
        fixture {
            val entered = CompletableDeferred<Unit>(); val cancelled = CompletableDeferred<Unit>()
            StreamResolver.extraction = { _, _ ->
                try { entered.complete(Unit); awaitCancellation() }
                finally { cancelled.complete(Unit) }
            }
            val selection = async { StreamResolver.resolve("abandoned") }; entered.await()
            selection.cancelAndJoin(); withContext(Dispatchers.Default) { withTimeout(3000) { cancelled.await() } }
        }
    }
    @Test fun accountSwitchRejectsObsoleteResponseAndDoesNotRetainIt() = runTest {
        fixture {
            StreamResolver.extraction = { id, _ ->
                Innertube.cookie = "SAPISID=synthetic-new-account"; stream(id)
            }
            assertFailsWith<CancellationException> { StreamResolver.resolve("switch") }
            StreamResolver.extraction = { id, _ -> stream("new-$id") }
            assertTrue(StreamResolver.resolve("switch")!!.url.endsWith("new-switch"))
        }
    }
    @Test fun tailRefusalInvalidatesOnlyIssuedTrackUrl() = runTest {
        fixture {
            var reads = 0
            StreamResolver.extraction = { id, _ -> stream("$id-${++reads}") }
            val original = StreamResolver.resolve("track")!!
            val other = StreamResolver.resolve("other")!!
            StreamResolver.onPlaybackRefused(original.url, 403)
            assertEquals(other, StreamResolver.resolve("other"))
            assertNotEquals(original.url, StreamResolver.resolve("track")!!.url)
            assertEquals(3, reads)
        }
    }
    @Test fun bitrateRequestsAreNotCoalescedAcrossDifferentCeilings() = runTest {
        fixture {
            val ceilings = mutableListOf<Int>()
            StreamResolver.extraction = { id, ceiling -> ceilings += ceiling; stream("$id-$ceiling") }
            assertNotEquals(StreamResolver.resolve("quality", 64), StreamResolver.resolve("quality", Int.MAX_VALUE))
            assertEquals(listOf(64, Int.MAX_VALUE), ceilings)
        }
    }

    private fun refused(vararg outcomes: String) = com.metrolist.innertubex.extraction.StreamResolveException(
        reason = com.metrolist.innertubex.extraction.StreamResolveException.Reason.NO_PLAYABLE_STREAM,
        message = "No playable stream found for this track.",
        diagnostics = com.metrolist.innertubex.extraction.StreamDiagnostics(
            attempts = outcomes.mapIndexed { i, outcome ->
                com.metrolist.innertubex.extraction.StreamAttemptDiagnostic("CLIENT$i", null, "ua", outcome)
            },
            usedAuthenticatedWatchPage = true,
        ),
    )

    /** Issue 17: a signed-in failure that wasn't a bot check must not be reported as one. */
    @Test fun signedInFailureWithoutLoginRequiredIsNotABotCheck() = runTest {
        fixture {
            Innertube.cookie = "SAPISID=synthetic"
            StreamResolver.extraction = { _, _ ->
                throw refused("selection:po_token", "playability:UNPLAYABLE", "request:IOException")
            }
            val error = assertFails { StreamResolver.resolve("signed-in-miss") }
            assertIs<com.metrolist.innertubex.extraction.StreamResolveException>(error)
            // And nothing is held back afterwards: the next track is asked for.
            var asked = false
            StreamResolver.extraction = { id, _ -> asked = true; stream(id) }
            assertNotNull(StreamResolver.resolve("next"))
            assertTrue(asked)
        }
    }

    @Test fun signedInBotCheckSaysSoWithoutAskingToSignIn() = runTest {
        fixture {
            Innertube.cookie = "SAPISID=synthetic"
            StreamResolver.extraction = { _, _ ->
                throw refused("playability:LOGIN_REQUIRED", "playability:LOGIN_REQUIRED")
            }
            val error = assertFailsWith<StreamResolver.BotCheckException> { StreamResolver.resolve("challenged") }
            assertTrue(error.message!!.contains("even signed in"))
        }
    }
}
