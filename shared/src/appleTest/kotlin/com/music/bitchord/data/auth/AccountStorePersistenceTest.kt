package com.music.bitchord.data.auth

import com.music.bitchord.data.settings.SecretStoreBridge
import com.music.bitchord.data.settings.SecretRead
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Uses the real Apple PlatformSettings bridge with an in-memory Keychain
 * implementation, so no test can touch the listener's credentials. */
class AccountStorePersistenceTest {
    private val secrets = mutableMapOf<String, String>()
    private var refuseWrites = false
    private var unavailableReads = false
    private var hideAfterRefusedWrite = false

    @BeforeTest
    fun setUp() {
        SecretStoreBridge.setImpl(object : SecretStoreBridge.Impl {
            override fun get(key: String): String? = if (unavailableReads) null else secrets[key]
            override fun read(key: String): SecretRead = SecretRead(get(key), !unavailableReads)
            override fun put(key: String, value: String?) {
                if (refuseWrites) {
                    if (hideAfterRefusedWrite) unavailableReads = true
                    return
                }
                if (value == null) secrets.remove(key) else secrets[key] = value
            }
        })
        refuseWrites = false
        unavailableReads = false
        hideAfterRefusedWrite = false
        AccountStore.restore()
    }

    @AfterTest
    fun tearDown() {
        secrets.clear()
        refuseWrites = false
        unavailableReads = false
        hideAfterRefusedWrite = false
        AccountStore.restore()
        SecretStoreBridge.setImpl(null)
    }

    @Test
    fun restores_the_account_and_channel_selected_before_relaunch() {
        val first = listOf(
            YouTubeProfile(profileId = "first", name = "First", pageId = "page-first"),
            YouTubeProfile(profileId = "second", name = "Second", pageId = "page-second"),
        )
        assertTrue(AccountStore.record("a", "SAPISID=a", "A", profiles = first))
        assertTrue(AccountStore.record(
            "b", "SAPISID=b", "B",
            profiles = listOf(YouTubeProfile(profileId = "third", name = "Third")),
        ))
        AccountStore.select("a", "second")

        // `restore` reloads from the encrypted blob; it must replace the
        // singleton's in-memory selection, just as a new process would.
        AccountStore.restore()
        assertEquals("a", AccountStore.activeSelection()?.account?.accountId)
        assertEquals("second", AccountStore.activeSelection()?.profile?.profileId)
    }

    @Test
    fun removing_active_account_restores_the_remaining_one() {
        assertTrue(AccountStore.record("a", "SAPISID=a", "A",
            profiles = listOf(YouTubeProfile(profileId = "one", name = "One"))))
        assertTrue(AccountStore.record("b", "SAPISID=b", "B",
            profiles = listOf(YouTubeProfile(profileId = "two", name = "Two"))))
        AccountStore.forget("b")
        AccountStore.restore()
        assertEquals("a", AccountStore.activeSelection()?.account?.accountId)
        assertEquals("one", AccountStore.activeSelection()?.profile?.profileId)
    }

    @Test
    fun failed_keychain_write_does_not_replace_or_remove_a_saved_session() {
        assertTrue(AccountStore.record("a", "SAPISID=a", "A",
            profiles = listOf(YouTubeProfile(profileId = "one", name = "One"))))
        refuseWrites = true
        assertEquals(false, AccountStore.record("b", "SAPISID=b", "B"))
        assertEquals(false, AccountStore.forget("a"))
        AccountStore.restore()
        assertEquals("a", AccountStore.activeSelection()?.account?.accountId)
        assertEquals("one", AccountStore.activeSelection()?.profile?.profileId)
    }

    @Test
    fun unavailable_read_after_failed_delete_is_not_successful_sign_out() {
        assertTrue(AccountStore.record("a", "SAPISID=test-fixture", "A",
            profiles = listOf(YouTubeProfile(profileId = "one", name = "One"))))
        val saved = secrets["account_sessions"]
        refuseWrites = true
        hideAfterRefusedWrite = true

        assertEquals(false, AccountStore.forget("a"))
        assertEquals(saved, secrets["account_sessions"])

        unavailableReads = false
        refuseWrites = false
        hideAfterRefusedWrite = false
        AccountStore.restore()
        assertEquals("a", AccountStore.activeSelection()?.account?.accountId)
    }

    @Test
    fun successful_last_account_deletion_remains_deleted_after_restore() {
        assertTrue(AccountStore.record("a", "SAPISID=test-fixture", "A"))
        assertTrue(AccountStore.forget("a"))
        assertEquals(null, secrets["account_sessions"])
        AccountStore.restore()
        assertTrue(AccountStore.accounts().isEmpty())
    }

    @Test
    fun older_list_blob_is_restored_and_upgraded_on_next_selection() {
        secrets["account_sessions"] = Json.encodeToString(
            ListSerializer(GoogleAccountSession.serializer()),
            listOf(GoogleAccountSession(
                accountId = "legacy", cookie = "SAPISID=legacy",
                profiles = listOf(YouTubeProfile(profileId = "channel", name = "Channel")),
                activeProfileId = "channel",
            )),
        )
        AccountStore.restore()
        assertEquals("legacy", AccountStore.activeSelection()?.account?.accountId)
        assertEquals("channel", AccountStore.activeSelection()?.profile?.profileId)
        assertTrue(AccountStore.select("legacy", "channel"))
        assertTrue(secrets["account_sessions"]?.contains("activeAccountId") == true)
    }
}
