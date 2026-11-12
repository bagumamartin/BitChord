package com.music.bitchord.data.http

import kotlin.test.*

class CredentialPolicyTest {
    @Test fun credentialRedirectsAreBoundToTheFullOrigin() {
        val origin = "https://example.invalid:8443/dav"
        assertTrue(CredentialPolicy.mayRedirect(origin, "$origin/folder", true))
        assertFalse(CredentialPolicy.mayRedirect(origin, "https://example.invalid:8444/dav", true))
        assertFalse(CredentialPolicy.mayRedirect(origin, "https://foreign.invalid/dav", true))
        assertFalse(CredentialPolicy.mayRedirect(origin, "http://example.invalid:8443/dav", true))
        assertFalse(CredentialPolicy.mayRedirect(origin, "https://user:password@example.invalid:8443/dav", true))
    }
    @Test fun publicRedirectsMayCrossOriginsButNeverDowngradeHTTPS() {
        assertTrue(CredentialPolicy.mayRedirect("https://one.invalid", "https://two.invalid", false))
        assertFalse(CredentialPolicy.mayRedirect("https://one.invalid", "http://two.invalid", false))
        assertTrue(CredentialPolicy.sameOrigin("https://EXAMPLE.invalid", "https://example.invalid:443/path"))
    }
    @Test fun theJarNeverServesGoogleHosts() {
        listOf("www.youtube.com", "music.youtube.com", "youtube.com", "YouTube.com.", "youtubei.googleapis.com",
            "rr3---sn-abc.googlevideo.com", "accounts.google.com", "i.ytimg.com").forEach {
            assertFalse(CredentialPolicy.jarServes(it), it)
        }
        listOf("open.spotify.com", "notyoutube.com", "youtube.com.example.invalid", null).forEach {
            assertTrue(CredentialPolicy.jarServes(it), it.toString())
        }
    }
}
