package com.music.bitchord.data.innertube

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * O9's video side is asked for by whichever surface is showing the picture, and
 * several surfaces can ask at once. One track must mean one request per
 * generation, and a second attach of the same track must reuse the answer
 * rather than mint another signed URL.
 */
class VideoSideCoalescingTest {
    private suspend fun ask(videoId: String, forceRefresh: Boolean = false) = withTimeout(5_000) {
        kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
            PlayerBridge.resolveVideo(videoId, forceRefresh = forceRefresh) { _, message ->
                if (message == null) continuation.resume(Unit)
                else continuation.resumeWithException(IllegalStateException(message))
            }
        }
    }

    private fun side(url: String = "https://media.invalid/video") = VideoSide(
        url = url,
        width = 1_920,
        height = 1_080,
        itag = 137,
        mimeType = "video/mp4; codecs=\"avc1.640028\"",
        codecs = "avc1.640028",
        bitrate = 2_800_000,
        headers = emptyMap(),
        availableVideoHeights = listOf(1_080),
        urlHasNParameter = false,
        clientName = "VISIONOS",
        profileId = "VISIONOS_0_1",
        musicVideoType = null,
    )

    private suspend fun withLoader(loader: suspend (String) -> VideoSide?, body: suspend () -> Unit) {
        val original = PlayerBridge.videoSideLoader
        PlayerBridge.videoSideLoader = loader
        try {
            body()
        } finally {
            PlayerBridge.videoSideLoader = original
        }
    }

    @Test
    fun concurrentAsksShareOneRequest() = runBlocking {
        var loads = 0
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        withLoader(
            {
                loads++
                entered.complete(Unit)
                release.await()
                // A real answer, not null: the second ask runs on the bridge's
                // own dispatcher and can arrive after the flight has landed,
                // and a null answer is deliberately not cached, so it flaked.
                side()
            }
        ) {
            val first = async { ask("coalesce-shared") }
            entered.await()
            val second = async { ask("coalesce-shared") }
            yield()
            release.complete(Unit)
            first.await()
            second.await()
        }
        assertEquals(1, loads)
    }

    @Test
    fun aSecondAskReusesTheCachedAnswer() = runBlocking {
        var loads = 0
        withLoader({ loads++; side() }) {
            ask("coalesce-cached")
            ask("coalesce-cached")
        }
        assertEquals(1, loads)
    }

    @Test
    fun aForcedAskBypassesTheCache() = runBlocking {
        var loads = 0
        withLoader({ loads++; side() }) {
            ask("coalesce-force")
            ask("coalesce-force", forceRefresh = true)
        }
        assertEquals(2, loads)
    }

    @Test
    fun aNullAnswerIsNotCached() = runBlocking {
        var loads = 0
        withLoader({ loads++; null }) {
            ask("coalesce-none")
            ask("coalesce-none")
        }
        assertEquals(2, loads)
    }

    @Test
    fun differentTracksDoNotShare() = runBlocking {
        var loads = 0
        withLoader({ loads++; null }) {
            ask("coalesce-one")
            ask("coalesce-two")
        }
        assertEquals(2, loads)
    }
}
