package com.music.bitchord.data.innertube

import com.metrolist.innertubex.extraction.StreamAttemptDiagnostic
import com.metrolist.innertubex.extraction.StreamDiagnostics
import com.metrolist.innertubex.extraction.StreamResolveException
import kotlin.test.Test
import kotlin.test.assertEquals

class ClientOutcomesTest {
    private fun failure(attempts: List<StreamAttemptDiagnostic>, authenticated: Boolean = false) =
        StreamResolveException(
            reason = StreamResolveException.Reason.NO_PLAYABLE_STREAM,
            message = "No playable stream found for this track.",
            diagnostics = StreamDiagnostics(attempts, usedAuthenticatedWatchPage = authenticated),
        )

    private fun attempt(client: String, outcome: String) =
        StreamAttemptDiagnostic(clientName = client, profileId = "p", userAgent = "UA/1.0 secret", outcome = outcome)

    @Test
    fun listsEachClientAndOutcomeWithoutUserAgents() {
        val outcomes = PlayerBridge.clientOutcomes(
            failure(listOf(attempt("VISIONOS", "playability:UNPLAYABLE"), attempt("WEB_REMIX", "formats:0")), authenticated = true)
        )
        assertEquals("\n[clients] authenticatedPage VISIONOS=playability:UNPLAYABLE, WEB_REMIX=formats:0", outcomes)
    }

    @Test
    fun findsTheExtractorFailureBehindAWrapper() {
        val wrapped = IllegalStateException("resolve failed", failure(listOf(attempt("IOS", "http:403"))))
        assertEquals("\n[clients] IOS=http:403", PlayerBridge.clientOutcomes(wrapped))
    }

    @Test
    fun addsNothingWithoutAttempts() {
        assertEquals("", PlayerBridge.clientOutcomes(failure(emptyList())))
        assertEquals("", PlayerBridge.clientOutcomes(IllegalStateException("network down")))
    }
}
