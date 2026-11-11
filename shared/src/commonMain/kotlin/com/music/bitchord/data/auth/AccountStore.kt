package com.music.bitchord.data.auth

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.innertube.Innertube
import com.music.bitchord.data.settings.PlatformSettings
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The signed-in accounts, and which YouTube identity is active, as Swift sees
 * it. Upstream `AuthStore` + `AccountSessions`, ported whole.
 *
 * ## Why accounts are stored as one JSON blob
 *
 * The alternative is a key per account, and a key per account means a key whose
 * *name* is an account id — which then has to be escaped, enumerated to find,
 * and removed when the last account goes. One JSON value under one key has
 * none of that: the accounts are a list, the list is the value, and clearing the
 * store is clearing the store.
 *
 * ## Why the whole blob is one secret
 *
 * A cookie is a credential: it grants full access to the account, so it belongs
 * in the Keychain rather than in `NSUserDefaults`. Upstream reaches the same
 * place with `EncryptedPrefs`, which is Android's Keystore-backed store, and
 * degrades to plain prefs when the Keystore is unavailable — a degradation this
 * port does not need, because the Keychain is always there.
 *
 * One key rather than one per account, deliberately. A key per account would
 * need the key's *name* to be an account id, which then has to be escaped,
 * enumerated to find, and removed when the last account goes. One value under
 * one key has none of that. It also means the existing `SECRET_KEYS` backup and
 * export path covers the accounts with no new entry, which a dynamic set of keys
 * could not do without that list becoming dynamic too.
 *
 * ## Why the id chains live in [AccountSessions] and not here
 *
 * They decide which account a selection refers to after a relaunch, and getting
 * one wrong does not produce an error — it produces a selection that silently
 * applies to the wrong account. That is testable arithmetic, so it is tested
 * there rather than buried in a store.
 */
object AccountStore {

    private val json = Json { ignoreUnknownKeys = true }

    private const val KEY = "account_sessions"

    /** The active account belongs with the accounts it selects. Older installs
     * stored only the list; [load] accepts that shape and upgrades on next save. */
    @Serializable
    private data class StoredState(
        val accounts: List<GoogleAccountSession>,
        val activeAccountId: String? = null,
    )

    /**
     * The active selection, kept here as well as inside the blob.
     *
     * Redundant on purpose: the selection is read on every single request's
     * header path, and walking a JSON list to find it would be the app's hottest
     * string operation. The blob stays the record; this is a cache of one field
     * of it, written on every change and cleared with it.
     */
    private var activeAccountId: String? = null
    private var activeProfileId: String? = null

    /** Every stored account, in the order it was added. */
    fun accounts(): List<GoogleAccountSession> = load()

    /** The account the selection names, or the first one when it names none. */
    fun activeAccount(): GoogleAccountSession? {
        val all = accounts()
        if (all.isEmpty()) return null
        return all.firstOrNull { it.accountId == activeAccountId } ?: all.first()
    }

    /**
     * The YouTube identity to listen as, and the account it belongs to.
     *
     * A record rather than a `Pair<GoogleAccountSession, YouTubeProfile>`, and
     * that is not a style choice. Kotlin/Native's Objective-C export cannot
     * express a non-null generic type parameter, so a `Pair` arrives in Swift
     * as `KotlinPair<A?, B?>` — both sides optional no matter what Kotlin says —
     * and the caller is left force-unwrapping values that are never nil. A named
     * record says what it is and keeps its nullability honest: one optional
     * answer, rather than two optional fields inside a non-optional box.
     *
     * Null when nothing is selected *or* when the account has no profiles: a
     * Google account always has at least one identity in the real world, so an
     * account with an empty list is a half-written record, and answering null
     * sends the request as the shell's own identity rather than as a channel
     * that does not exist.
     */
    fun activeSelection(): ActiveSelection? {
        val account = activeAccount() ?: return null
        val profile = account.profiles.firstOrNull { it.profileId == activeProfileId }
            ?: account.profiles.firstOrNull()
            ?: return null
        return ActiveSelection(account, profile)
    }

    /** Reapply the saved cookie and channel at launch or after a rejected
     * candidate. No write is made, so a locked Keychain is left untouched. */
    fun restore() {
        accounts()
        apply()
    }

    /**
     * Records a signed-in account, replacing any with the same id, and selects
     * it.
     *
     * The account is stored with whatever profiles Google reported. A re-login
     * replaces the record rather than merging into it: a channel the listener
     * has since lost access to must not keep being offered, and a merge would
     * have no way to tell that apart from one they kept.
     */
    fun record(
        accountId: String,
        cookie: String,
        name: String = "",
        email: String = "",
        profiles: List<YouTubeProfile> = emptyList(),
    ): Boolean {
        if (cookie.isBlank()) return false
        val all = accounts().toMutableList()
        val id = accountId.ifBlank { sessionIdOf(cookie, null) }
        val session = GoogleAccountSession(
            accountId = id,
            cookie = cookie,
            name = name,
            email = email,
            profiles = profiles,
            activeProfileId = profiles.firstOrNull()?.profileId,
        )
        val at = all.indexOfFirst { it.accountId == id }
        if (at >= 0) all[at] = session else all.add(session)
        activeAccountId = id
        activeProfileId = session.activeProfileId
        if (!save(all)) {
            load()
            return false
        }
        apply()
        return true
    }

    /** Forgets an account. The selection moves to whatever is left, or to none. */
    fun forget(accountId: String): Boolean {
        val all = accounts().filterNot { it.accountId == accountId }
        if (activeAccountId == accountId) {
            activeAccountId = all.firstOrNull()?.accountId
            activeProfileId = all.firstOrNull()?.activeProfileId
        }
        if (!save(all)) {
            load()
            return false
        }
        apply()
        return true
    }

    /**
     * Selects an identity, and tells Innertube about it.
     *
     * The two are done together on purpose. A selection the requests do not
     * know about is the worst state this can be in: the menu says one channel
     * and the library is the other's, and nothing on screen contradicts
     * anything.
     */
    fun select(accountId: String?, profileId: String?): Boolean {
        val all = accounts()
        val account = all.firstOrNull { it.accountId == accountId }
            ?: return false
        // Set only after the account is known to exist, so a selection naming a
        // forgotten account cannot leave the headers pointing at a cookie that
        // is no longer stored.
        activeAccountId = account.accountId
        val profile = account.profiles.firstOrNull { it.profileId == profileId }
        activeProfileId = profile?.profileId
        if (!save(all.map {
            if (it.accountId == account.accountId) {
                it.copy(activeProfileId = activeProfileId)
            } else {
                it
            }
        })) {
            load()
            return false
        }
        apply()
        return true
    }

    /**
     * Moves the selection one step through every stored identity.
     *
     * Returns false at either end rather than wrapping — see [adjacentProfile].
     */
    fun step(forward: Boolean): Boolean {
        val all = accounts()
        val next = adjacentProfile(all, activeAccountId, activeProfileId, forward) ?: return false
        return select(next.first, next.second)
    }

    /**
     * Puts the selection into effect: the chosen cookie on [Innertube], and the
     * chosen channel as an override.
     *
     * Both halves, always together. Applying the cookie without the channel
     * would browse as the account's *default* identity while the menu claimed a
     * different one — the specific half-applied state that is worse than
     * either.
     */
    private fun apply() {
        val account = activeAccount()
        if (account == null) {
            Innertube.cookie = null
            Innertube.adoptPageScope(null, null, null)
            return
        }
        Innertube.cookie = account.cookie
        val profile = activeSelection()?.profile
        Innertube.adoptPageScope(profile?.pageId, profile?.dataSyncId, profile?.authUser)
        DebugLog.d(
            "acting as channel pageId=${profile?.pageId ?: "none"} " +
                "authUser=${profile?.authUser ?: "as-is"} (account=${account.accountId})",
        )
    }

    private fun load(): List<GoogleAccountSession> {
        val raw = PlatformSettings.getSecret(KEY) ?: return emptyList()
        val state = runCatching { json.decodeFromString(StoredState.serializer(), raw) }.getOrNull()
            ?: StoredState(
                accounts = runCatching {
                    json.decodeFromString(ListSerializer(GoogleAccountSession.serializer()), raw)
                }.getOrDefault(emptyList()),
            )
        val valid = state.accounts
            // A record with no cookie is unusable — there is nothing to sign a
            // request with — so it is dropped rather than surfaced as an account
            // that cannot be selected.
            .filter { it.cookie.isNotBlank() }
        val active = valid.firstOrNull { it.accountId == state.activeAccountId } ?: valid.firstOrNull()
        activeAccountId = active?.accountId
        activeProfileId = active?.activeProfileId
        return valid
    }

    private fun save(all: List<GoogleAccountSession>): Boolean {
        if (all.isEmpty()) {
            if (!PlatformSettings.writeSecret(KEY, null)) return false
            val verified = PlatformSettings.readSecret(KEY)
            if (!verified.available || verified.value != null) return false
            activeAccountId = null
            activeProfileId = null
            return true
        }
        val encoded = json.encodeToString(
            StoredState.serializer(), StoredState(all, activeAccountId)
        )
        if (!PlatformSettings.writeSecret(KEY, encoded)) return false
        val verified = PlatformSettings.readSecret(KEY)
        val saved = verified.available && verified.value == encoded
        if (!saved) DebugLog.w("could not persist account sessions")
        return saved
    }
}
