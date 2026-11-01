package com.music.bitchord.data.sources

import com.music.bitchord.data.DebugLog
import com.music.bitchord.data.model.Song
import com.music.bitchord.data.settings.AppSettings
import com.music.bitchord.data.settings.DownloadQuality
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/**
 * Port of upstream `data/sources/SourceResolver.kt` — turns a queued track into an
 * openable stream, using whichever source can best serve it.
 *
 * Two things happen here that don't happen in any single [MusicSource]:
 *
 *  1. **The quality question is answered once**, from the connection in hand and
 *     the user's ceiling for it — see [requestForNow], or [requestForDownload] for
 *     the one caller whose answer becomes a file rather than a stream. Sources are
 *     told what to serve; they don't each re-derive it.
 *
 *  2. **The order is applied.** A track is pinned to the source that produced it,
 *     but a pin is a starting point, not a cage: with lossless on, a
 *     higher-priority source that can serve the same recording bit-exact gets asked
 *     first, and a source that fails gets stepped over rather than failing the
 *     track.
 *
 * Whether another source *has* the same recording is [TrackMatcher]'s question, not
 * this one's. Everything here does with a candidate list is ask that, and everything
 * a source is asked for comes from the same place — so the library, a playlist,
 * radio, search and the home feed all substitute on identical terms, whichever of
 * them a track was queued from.
 *
 * Before this existed the port had a reduced Swift reimplementation of a few of
 * these decisions, with no ranked list to walk and no shared contract — which is
 * why a source the user had configured and ranked above YouTube did nothing for
 * anything *queued* from YouTube, and only search results honoured it.
 */
object SourceResolver {

    // ── What to ask for ─────────────────────────────────────────────────────

    /**
     * What to ask a source for, right now.
     *
     * The lossless rung loses to the connection's own ceiling, which is the setting
     * someone reached for specifically to protect a data plan. A capped connection
     * gets a capped transcode whether or not lossless is on, because the
     * alternative is a switch in one part of Settings quietly undoing a switch in
     * another, and the one being undone is the one attached to a bill.
     */
    fun requestForNow(): StreamRequest {
        val ceiling = AppSettings.effectiveAudioQualityFlow.value
        return when {
            ceiling == com.music.bitchord.data.settings.AudioQuality.LOSSLESS -> StreamRequest.Lossless
            ceiling.maxKbps == Int.MAX_VALUE -> StreamRequest.Best
            else -> StreamRequest.Capped(ceiling.maxKbps)
        }
    }

    /**
     * What to ask a source for on behalf of a file being kept.
     *
     * Reads the download-quality setting and nothing else — not the stream ceilings,
     * not the lossless rung. Both of those are about what a *stream* costs on the
     * connection in hand, and this is the one request whose answer outlives the
     * connection: it becomes a file.
     *
     * That independence is the point. The ceilings used to decide this by proxy, so
     * downloading on capped mobile data returned a transcode even for someone whose
     * own lossless server was ranked above YouTube — a setting about data spend
     * silently deciding what a permanent file was made of. When a download may be
     * fetched is the Wi-Fi-only setting's question, asked once at the point of
     * queueing rather than mixed in here.
     *
     * @param quality defaults to the setting as it stands. A caller already
     *   fetching one passes the value it started with — a lossless search can run
     *   for twenty seconds, which is long enough for someone to open Settings and
     *   change the answer underneath a file that is half written.
     */
    fun requestForDownload(
        quality: DownloadQuality = AppSettings.downloadQuality.value,
    ): StreamRequest = when {
        quality.keepsLossless -> StreamRequest.Lossless
        quality.maxKbps == Int.MAX_VALUE -> StreamRequest.Best
        else -> StreamRequest.Capped(quality.maxKbps)
    }

    // ── Playback ────────────────────────────────────────────────────────────

    /**
     * The stream for a source-backed track.
     *
     * @param target is what a cross-source match is made on. Without it the only
     *   possible behaviour is "the pinned source or nothing", which is still a
     *   correct outcome — just a worse one.
     */
    suspend fun resolve(
        configId: String,
        trackId: String,
        target: TrackMatcher.Target,
    ): SourceStream? {
        val request = requestForNow()
        val active = SourceRegistry.activeForPlayback()
        // A pin identifies where the row originally came from; it does not override
        // the source switch. Looking the instance up directly would reopen disabled
        // sources for tracks already sitting in the queue. Resolving the pin only
        // from the enabled list makes Off mean off for both newly matched tracks and
        // source-backed rows queued earlier.
        val pinned = active.firstOrNull { it.configId == configId }

        // The upgrade path: with lossless asked for and the pinned source unable to
        // serve it, anything ranked above it that can is worth asking first. This is
        // the whole reason the list is ordered — it is what makes "my own FLAC of
        // this, if I have one, else stream it" expressible.
        if (request is StreamRequest.Lossless && pinned?.kind?.canServeLossless != true) {
            for (source in rankedAbove(configId, active)) {
                if (!source.kind.canServeLossless) continue
                val upgraded = matchAndStream(source, target, request) ?: continue
                // Only a genuinely lossless answer is an upgrade. A source that
                // *can* serve lossless but settled for a transcode of this
                // particular track has not beaten the pinned source at anything —
                // and returning its settle-for here jumped ahead of the track's own
                // source, which is the one the user picked and may well hold
                // something better. It falls through to the pinned source instead,
                // and to [bestAcross] below if that fails.
                if (upgraded.format.isLossless != true) continue
                DebugLog.d("lossless upgrade: '${target.title}' served by ${source.displayName}")
                return upgraded
            }
        }

        if (pinned != null) {
            val pinnedStream = attempt(pinned) { pinned.stream(trackId, request) }?.let { StreamVerification.verify(it) }
            if (pinnedStream != null) {
                if (!rejectUnsupportedNativeStream(pinned, pinnedStream, target.title)) {
                    return pinnedStream.copy(sourceConfigId = pinned.configId)
                }
            }
        }

        // Last resort. A track whose own source is down is still a track the user
        // asked for, and another source having it is not unlikely — this is the
        // difference between a dead server skipping the queue forward and a dead
        // server being invisible.
        val (fallbackSource, stream) =
            bestAcross(active.filterNot { it.configId == configId }, target, request) ?: return null
        DebugLog.d("fallback: '${target.title}' served by ${fallbackSource.displayName}")
        return stream
    }

    /**
     * The stream for a YouTube track from a source the user ranked above YouTube, or
     * null when none of them has the recording.
     *
     * A YouTube track keeps its bare video id rather than a
     * [SourceRegistry.trackKey] — see [YouTubeSource] for why — so it reaches
     * playback as `bitchord://watch?v=…` and never passes through [resolve].
     * Without this, ordering a source above YouTube did nothing for anything
     * *queued* from YouTube: the library, a playlist, radio, the home feed — which
     * is very nearly everything. The list said "prefer my server" and only search
     * results honoured it.
     *
     * The match is the same strict one [resolve] uses, for the same reason: this
     * substitutes something else for the track the user picked, and a loose match
     * plays the wrong song under the right title.
     *
     * Sources race concurrently. Lossless collects the best answer for up to
     * 2.5 seconds; other tiers keep the first-usable latency policy. The host's
     * separate three-second fallback deadline still bounds time to first sound.
     */
    suspend fun substituteForYouTube(target: TrackMatcher.Target): SourceStream? {
        // Video rows always use YouTube's own stream unless the listener explicitly
        // converts the current item in the player. A source match is another
        // recording and can be a wrong song altogether.
        if (target.title.isBlank() || target.isVideo) return null
        val active = SourceRegistry.activeForPlayback()
        val youtube = active.firstOrNull { it.kind == SourceKind.YOUTUBE } ?: return null
        val requested = requestForNow()
        val mayUseLossless = PlaybackCodecCapabilities.allowLosslessSources
        // The quality setting decides; the output route does not. The physical
        // output capability only applies to addons that explicitly require it.
        val routeRequest = if (requested is StreamRequest.Lossless && !mayUseLossless) StreamRequest.Best else requested
        val (source, stream) = bestAcross(
            rankedAbove(youtube.configId, active), target, routeRequest,
            allowLossless = mayUseLossless,
            accept = { _, candidate -> mayUseLossless || candidate.format.isLossless != true },
        )
            ?: return null
        // Says what was found, not what the caller will do with it. This line used
        // to read "substituted" unconditionally, including for streams the caller
        // went on to refuse — which made a log of a track that played on YouTube
        // look like a track that hadn't.
        DebugLog.d(
            "substituted: '${target.title}' served by ${source.displayName} over YouTube" +
                " at ${stream.format.summary}" + if (stream.belowRequest) " (below request)" else "",
        )
        return stream
    }

    /**
     * The reliable last rung for a source-backed queue item whose chosen stream
     * failed in the player.
     *
     * Unlike [resolve], this asks only YouTube — the failed source must not get
     * another chance to return the identical URL — and unlike
     * [substituteForYouTube] it starts with metadata rather than an existing video
     * id, so it first finds the matching YouTube Music row.
     */
    suspend fun youtubeFallback(target: TrackMatcher.Target): SourceStream? {
        if (target.title.isBlank() || target.isVideo) return null
        val youtube = SourceRegistry.activeForPlayback()
            .firstOrNull { it.kind == SourceKind.YOUTUBE }
            ?: return null
        return matchAndStream(
            source = youtube,
            target = target,
            request = StreamRequest.Best,
            strictLength = target.durationSec != null,
            requireSharedArtist = true,
        )?.also {
            DebugLog.d("YouTube fallback matched '${target.title}' after its higher-quality source failed")
        }
    }

    /** Prepare the next track using every preferred source, including slower addons.
     * Lossless gets up to twelve seconds while the current track is still playing.
     * The caller must retain this exact answer before buffering it.
     */
    suspend fun prefetchSubstitute(target: TrackMatcher.Target): SourceStream? {
        if (target.title.isBlank() || target.isVideo) return null
        val active = SourceRegistry.activeForPlayback()
        val youtube = active.firstOrNull { it.kind == SourceKind.YOUTUBE } ?: return null
        val preferred = rankedAbove(youtube.configId, active)
        val request = requestForNow()
        val mayUseLossless = PlaybackCodecCapabilities.allowLosslessSources
        val routeRequest = if (request is StreamRequest.Lossless && !mayUseLossless) StreamRequest.Best else request
        val (source, stream) = bestAcross(
            preferred, target, routeRequest,
            waitForAll = true,
            selectionWindowMs = if (routeRequest is StreamRequest.Lossless) 12_000 else 2_500,
            allowLossless = mayUseLossless,
            accept = { _, candidate -> mayUseLossless || candidate.format.isLossless != true },
        ) ?: return null
        DebugLog.d("warmed: '${target.title}' from ${source.displayName} at ${stream.format.summary}")
        return stream
    }

    /**
     * A stream that genuinely satisfies the current request, for a track already
     * playing on one that doesn't — or null if there isn't one.
     *
     * The same search as [substituteForYouTube] with two differences, both only
     * affordable because sound is already coming out:
     *
     *  - Every source *within* a source is waited for, including the one the live
     *    path gave up on to get playback started (`waitForAll`). That one is
     *    frequently the point: dropping it is what left the listener on whichever
     *    source happened to be quick.
     *  - A result that isn't lossless is still worth having when it is audibly
     *    better than what is playing — see [worthSwapping]. Refusing those outright
     *    is what left a track on 160kbps Opus while a 320kbps AAC from a source sat
     *    in hand, unused, because it wasn't the FLAC that had been asked for.
     *
     * [target] must carry the runtime of the track *actually playing*. Swapping the
     * audio under a listener is only defensible when the replacement is the same
     * recording, and length is the check that a title cannot fake.
     *
     * @param playing what the listener is hearing now, so a lossy candidate can be
     *   judged against it rather than against the request. Null means unknown, and
     *   an unknown floor is treated as one nothing lossy clears: a swap that might
     *   be a downgrade is worse than no swap at all.
     * @param servedBy the config id already serving the track, if known. Asking it
     *   again is wasted: the same source, asked the same query at the same tier, is
     *   deterministic and can only reproduce the stream already playing — which
     *   [worthSwapping] would reject anyway, but not before spending a search and a
     *   stream call on it.
     */
    suspend fun upgradeFor(
        target: TrackMatcher.Target,
        playing: StreamFormat? = null,
        servedBy: String? = null,
    ): SourceStream? {
        if (target.title.isBlank() || target.durationSec == null || target.isVideo) return null
        val active = SourceRegistry.activeForPlayback()
        val youtube = active.firstOrNull { it.kind == SourceKind.YOUTUBE } ?: return null
        // Every source gets asked, whether or not it can serve lossless, and they are
        // asked at once.
        //
        // There used to be a `canServeLossless` skip here, applied whenever the
        // request was Lossless — which is what an unmetered connection asks for, so
        // nearly always. Its reasoning was that only a lossless source can satisfy a
        // lossless request, and that is true and beside the point: this function is
        // not serving the request, it is deciding whether anything beats what is
        // *already playing*. [worthSwapping] is the bar for that, and a 320kbps
        // source clears it over 160kbps Opus by nearly twice the required margin.
        //
        // Racing them matters as much as asking them. Walked in rank order this took
        // 13.6s on one track — a source needed 7.6s to search and another 5.0s to
        // produce a 128kbps MP3 that was then refused, and only after all of that
        // was JioSaavn asked, which answered with 320kbps in 246ms.
        val (source, chosen) = bestAcross(
            rankedAbove(youtube.configId, active).filterNot { it.configId == servedBy },
            target,
            if (requestForNow() is StreamRequest.Lossless && !PlaybackCodecCapabilities.allowLosslessSources) {
                StreamRequest.Best
            } else requestForNow(),
            waitForAll = true,
            strictLength = true,
            requireSharedArtist = true,
            allowLossless = PlaybackCodecCapabilities.allowLosslessSources,
        ) { candidate, stream ->
            (PlaybackCodecCapabilities.allowLosslessSources || stream.format.isLossless != true) &&
                worthSwapping(stream.format, playing).also { worth ->
                // Named rather than skipped silently. This is the one refusal in the
                // upgrade path that discards a stream already found, matched and
                // length-checked, and a silent skip reads in the log exactly like a
                // source having nothing.
                if (!worth) {
                    DebugLog.d(
                        "${candidate.displayName}'s ${stream.format.summary} isn't worth swapping " +
                            "'${target.title}' off ${playing?.summary ?: "an unmeasured stream"}",
                    )
                }
            }
        } ?: return null
        DebugLog.d("upgrade found: '${target.title}' at ${chosen.format.summary} from ${source.displayName}")
        return chosen
    }

    // ── Download ────────────────────────────────────────────────────────────

    /**
     * The copy of a track about to be downloaded that is worth keeping over
     * YouTube's, or null when nothing configured has one.
     *
     * The download path has never come through here upstream. It resolves YouTube
     * directly, so someone with a lossless server ranked above YouTube was
     * *streaming* the lossless copy and *downloading* a transcode of the same
     * recording. This closes that gap, and it is the only search here whose result
     * becomes a file.
     *
     * ### The order it asks in
     *
     *  1. **Bit-exact, in rank order** — on the Lossless rung only, since that is
     *     the only rung asking for it. The first source that hands back a genuinely
     *     lossless file wins outright and nothing else is asked: it is the whole
     *     point of the setting and no bitrate competes with it.
     *  2. **The best lossy copy otherwise.** A lossless source that settled for a
     *     transcode is not thereby wasted — its offer is kept and weighed against
     *     what the lossy sources hold, and the better rendition wins on [isBetter].
     *     This is where JioSaavn's 320kbps AAC comes in.
     *  3. **YouTube**, by this returning null. Which is not a failure — see the floor
     *     below.
     *
     * Steps 1 and 2 are started together rather than in sequence. A module search
     * runs to twenty seconds and JioSaavn answers in about four tenths of one, and
     * the whole lookup is on a clock: queued behind the modules, the fast source
     * would routinely have the timeout land on it and the download would fall to
     * YouTube holding a 320 it never got to hear about.
     *
     * ### The floor, and why a lossy answer can still lose to YouTube
     *
     * A lossy candidate is only kept if it beats [YOUTUBE_BEST_AAC_KBPS] — the top
     * of YouTube's own AAC ladder. Anything at or under that is trading one lossy
     * copy for another and giving up the more reliable fetch to do it. So a 320 wins
     * and a 128kbps MP3 does not, and neither does a format that never stated a
     * bitrate: a download has to *name the file* before the first byte lands, and
     * an unstated rendition is nothing to judge. That is stricter than
     * [streamBest]'s [statesNothingLossy] allowance, deliberately — playback can
     * hand an undescribed URL to the decoder and let it work the codec out.
     *
     * @param target the recording to look for, off the row being downloaded. A
     *   blank title can only produce a wrong match; a null runtime is allowed and
     *   costs the length check rather than the search.
     */
    suspend fun forDownload(
        target: TrackMatcher.Target,
        request: StreamRequest = requestForDownload(),
    ): SourceStream? = coroutineScope {
        if (target.title.isBlank()) return@coroutineScope null
        val wantsLossless = when (request) {
            is StreamRequest.Lossless -> true
            is StreamRequest.Best -> false
            // Standard, and the one rung the sources are no use for: it is a ceiling
            // of 128kbps chosen to fit more on the device, and a source has no way
            // to be asked for *that* rung rather than for the best it has.
            // JioSaavn's 320 is not a better answer to it, it is the wrong answer.
            // YouTube's ladder is the only one that can be capped.
            is StreamRequest.Capped -> return@coroutineScope null
        }
        // SourceRegistry.active, not the playback list: a download is not budgeted by
        // the connection's streaming ceiling. What it keeps is the download
        // setting's answer and what it may spend is the Wi-Fi-only setting's, and a
        // mobile-data rung of Medium has no business deciding that a file saved over
        // Wi-Fi later is a YouTube one.
        // An addon that publishes `allowDownloads: 0` is playback-only.
        val active = SourceRegistry.active().filter { (it as? AddonSource)?.allowsDownloads() != false }
        // YouTube can be switched off, and a download still goes to it when nothing
        // here answers. So an absent YouTube means everything enabled outranks it,
        // which is already what [rankedAbove] says about a config not in the list.
        val youtubeId = active.firstOrNull { it.kind == SourceKind.YOUTUBE }?.configId
        val ranked = rankedAbove(youtubeId.orEmpty(), active)
        val strictLength = target.durationSec != null

        // Who is in the bit-exact walk, and who is left to the race below it. On the
        // High rung nobody is: there is no lossless answer to look for, so every
        // ranked source goes into the race and competes on rendition alone. That is
        // what puts a lossy source's 320 in front of YouTube's AAC for a setting
        // whose own description is "best AAC on offer".
        val bitExact = if (wantsLossless) ranked.filter { it.kind.canServeLossless } else emptyList()
        val elsewhere = ranked - bitExact.toSet()

        val elsewhereBest = async {
            bestAcross(
                elsewhere,
                target,
                // Their best lossy rendition, whichever rung is being served. Putting
                // the lossless request to a source that cannot meet it would only
                // come back marked `belowRequest` to say so.
                StreamRequest.Best,
                waitForAll = true,
                strictLength = strictLength,
            ) { source, stream ->
                // Bit-exact audio is *over* budget on the High rung, not a bonus on
                // it. Someone who picked High over Lossless picked the smaller
                // file, and a lossless file filed under this setting would also be
                // missed by the already-on-disk check, which only looks for lossless
                // extensions when the setting keeps lossless — so it would be
                // re-downloaded every time.
                val ok = wantsLossless || stream.format.isLossless != true
                if (!ok) {
                    DebugLog.d(
                        "${source.displayName} offered ${stream.format.summary}; " +
                            "more than this download asked for",
                    )
                }
                ok
            }
        }

        var best: Pair<MusicSource, SourceStream>? = null
        for (source in bitExact) {
            val stream = matchAndStream(
                source = source,
                target = target,
                // The request the guard above already narrowed, rather than a second
                // statement of it that could drift from the first.
                request = request,
                waitForAll = true,
                strictLength = strictLength,
            ) ?: continue
            // Dolby Atmos is not bit-exact PCM, but it is the native premium
            // rendition that playback already prefers. Keep it on the same
            // first-class download path instead of throwing it away and falling back
            // to YouTube solely because it has no bitrate tag.
            if (stream.format.isLossless == true || stream.format.isDolbyAtmos) {
                DebugLog.d("download: '${target.title}' from ${source.displayName} at ${stream.format.summary}")
                // Nothing is waiting on it any more, and leaving it running would hold
                // this whole call open on a source whose answer has just been beaten
                // by the requested premium rendition.
                elsewhereBest.cancel()
                return@coroutineScope stream
            }
            DebugLog.d("${source.displayName} offered ${stream.format.summary} to download; not lossless or Dolby")
            if (isBetter(stream.format, best?.second?.format)) best = source to stream
        }

        // Nothing bit-exact anywhere — or nothing was being looked for. Whatever is
        // left competes on rendition alone, wherever it came from.
        elsewhereBest.await()?.let { (source, stream) ->
            if (isBetter(stream.format, best?.second?.format)) best = source to stream
        }
        val (winner, chosen) = best ?: return@coroutineScope null
        if (!beatsYouTubeAac(chosen.format)) {
            DebugLog.d(
                "best offered for '${target.title}' is ${winner.displayName}'s " +
                    "${chosen.format.summary}; taking YouTube's AAC over that",
            )
            return@coroutineScope null
        }
        DebugLog.d(
            "download: '${target.title}' from ${winner.displayName} at ${chosen.format.summary}, " +
                "over YouTube's AAC",
        )
        chosen
    }

    /**
     * Whether a lossy [candidate] is worth keeping as a file over whatever YouTube's
     * own AAC ladder would have given for the same track.
     *
     * An unstated bitrate is a no: a download has to name the file before the first
     * byte lands, and a rendition that described itself as nothing is nothing to
     * weigh.
     */
    internal fun beatsYouTubeAac(candidate: StreamFormat): Boolean =
        (candidate.kbps ?: 0) > YOUTUBE_BEST_AAC_KBPS

    /**
     * Whether [candidate] is enough better than [playing] to be worth the break in
     * the audio that swapping to it costs.
     *
     * Lossless always is: it is what was asked for, and the whole point.
     *
     * Lossy swaps need the same codec family and a bitrate gain of at least
     * [UPGRADE_MIN_GAIN_KBPS]. Cross-codec bitrates do not establish an upgrade.
     * Lossless-to-lossless changes must improve decoded precision without
     * reducing the other known format dimension.
     */
    internal fun worthSwapping(candidate: StreamFormat, playing: StreamFormat?): Boolean {
        // Never away from an immersive mix. A FLAC is a better *copy* and a worse
        // *mix* once Atmos is what the listener chose, and cutting one in over the
        // other mid-song is a downgrade dressed as an upgrade.
        if (playing?.isDolbyAtmos == true && !candidate.isDolbyAtmos) return false
        if (candidate.isDolbyAtmos) return playing?.isDolbyAtmos != true
        if (candidate.isLossless == true) return playing?.isLossless != true || isBetter(candidate, playing)
        val baseline = playing ?: return false
        if (baseline.isLossless == true || candidate.codecFamily == null || candidate.codecFamily != baseline.codecFamily) return false
        val gain = (candidate.kbps ?: return false) - (baseline.kbps ?: return false)
        return gain >= UPGRADE_MIN_GAIN_KBPS
    }

    /**
     * Whether two runtimes are close enough to be the same recording, for a swap
     * into a track that is already playing.
     *
     * Either side being unknown is a no. An unverifiable length is not a length that
     * agrees, and the cost of being wrong here is a listener's song replaced
     * mid-play by a different cut of it.
     */
    fun sameRecordingAs(candidateSec: Int?, playingSec: Int?): Boolean {
        if (candidateSec == null || playingSec == null) return false
        return abs(candidateSec - playingSec) <= upgradeLengthSlackSeconds()
    }

    private fun upgradeLengthSlackSeconds(): Int =
        runCatching { AppSettings.upgradeLengthSlackSeconds.value }.getOrDefault(3).coerceIn(0, 10)

    /**
     * Whether anything outranks YouTube right now — i.e. whether a YouTube track is
     * worth offering around before it is resolved.
     *
     * Answerable from the source list alone, without a search, which is what lets
     * the cache and the read-ahead decide how to treat a YouTube id before anyone
     * has asked a source for it.
     */
    fun canSubstituteForYouTube(): Boolean =
        SourceRegistry.activeForPlayback().indexOfFirst { it.kind == SourceKind.YOUTUBE } > 0

    // ── The race ────────────────────────────────────────────────────────────

    /**
     * The sources ranked above [configId], in order.
     *
     * A config that isn't in [active] ranks last: it is disabled or incomplete, and
     * everything that *is* enabled is worth trying ahead of it.
     */
    private fun rankedAbove(configId: String, active: List<MusicSource>): List<MusicSource> {
        val index = active.indexOfFirst { it.configId == configId }
        return active.take(if (index < 0) active.size else index)
    }

    /**
     * Ask sources concurrently and keep the best rendition. A positive
     * [selectionWindowMs] bounds collection, including patient per-source lookups;
     * expiry returns the best completed answer and cancels outstanding work.
     * With no window, [waitForAll] chooses between first usable and all results.
     * Equal-quality answers follow the configured source order.
     */
    internal suspend fun bestAcross(
        sources: List<MusicSource>,
        target: TrackMatcher.Target,
        request: StreamRequest,
        waitForAll: Boolean = false,
        strictLength: Boolean = false,
        requireSharedArtist: Boolean = false,
        allowLossless: Boolean = true,
        selectionWindowMs: Long = if (!waitForAll && request is StreamRequest.Lossless) 2_500 else 0,
        accept: (MusicSource, SourceStream) -> Boolean = { _, _ -> true },
    ): Pair<MusicSource, SourceStream>? = coroutineScope {
        val running: MutableList<Deferred<Pair<MusicSource, SourceStream?>>> = sources
            .map { source ->
                async {
                    source to matchAndStream(
                        source = source,
                        target = target,
                        request = request,
                        waitForAll = waitForAll,
                        strictLength = strictLength,
                        requireSharedArtist = requireSharedArtist,
                        allowLossless = allowLossless,
                    )
                }
            }
            .toMutableList()
        var best: Pair<MusicSource, SourceStream>? = null
        suspend fun collect() {
            while (running.isNotEmpty()) {
                val first = select {
                    running.forEach { candidate -> candidate.onAwait { candidate } }
                }
                // Anything that crossed the line while that one was being waited on is
                // already sitting there. Folding those in costs no time at all and is
                // what lets rank break a tie between two sources that both answered
                // quickly.
                val ready = listOf(first) + running.filter { it !== first && it.isCompleted }
                running -= ready.toSet()
                for (done in ready) {
                    val (source, stream) = done.await()
                    if (stream == null) continue
                    if (!accept(source, stream)) continue
                    val previous = best
                    if (isBetter(stream.format, previous?.second?.format) ||
                        (previous != null && !isBetter(previous.second.format, stream.format) &&
                            sources.indexOf(source) < sources.indexOf(previous.first))) {
                        best = source to stream
                    }
                }
                // Playback needs the first usable answer so sound can start. An upgrade
                // is different: it runs while audio is already playing, and its caller
                // explicitly requested every source's patient result. Let every source
                // finish so a fast lower tier cannot cancel a later, better rendition.
                if (best != null && !waitForAll && selectionWindowMs <= 0) break
            }
        }
        try {
            if (selectionWindowMs > 0) {
                // Keep the best answer across the whole bounded window. A fast
                // transcode must not cancel another provider's pending FLAC.
                if (withTimeoutOrNull(selectionWindowMs) { collect(); true } == null) {
                    SourceResolutionReport.record("timeout")
                }
            } else {
                collect()
            }
        } finally {
            running.forEach { it.cancel() }
        }
        best
    }

    /**
     * Searches [source] for the recording in [target] and streams it if one of the
     * answers really is that recording — see [TrackMatcher].
     *
     * Each query the matcher offers is tried in turn, because the first one failing
     * is usually the catalogue disagreeing about how a track is *filed*, not about
     * whether it holds it. Stopping at the first empty answer is what made a source
     * look like it was missing half of what it had. A source that *throws* still
     * gets no second chance: that is its server having a problem, and asking it
     * again differently won't fix it.
     *
     * @param waitForAll holds a multi-backend search open for every backend instead
     *   of answering from whichever of them are quick — affordable only when nobody
     *   is waiting on the first note.
     * @param strictLength requires a candidate's runtime to agree with [target]'s to
     *   within the configured upgrade-length slack. Kept apart from [waitForAll] because it is only
     *   meaningful when the target *has* a runtime: asking for it against a target
     *   that never carried a duration is not a strict search but an empty one.
     */
    private suspend fun matchAndStream(
        source: MusicSource,
        target: TrackMatcher.Target,
        request: StreamRequest,
        waitForAll: Boolean = false,
        strictLength: Boolean = false,
        requireSharedArtist: Boolean = false,
        allowLossless: Boolean = true,
    ): SourceStream? {
        for (query in TrackMatcher.queries(target)) {
            val candidates = attempt(source) {
                source.search(
                    query = query,
                    limit = MATCH_CANDIDATES,
                    waitForAll = waitForAll,
                    // The search and the stream are one question here: a catalogue
                    // that files its rows by tier should describe them at the tier
                    // this is about to ask for.
                    request = request,
                )
            } ?: return null
            var matches = TrackMatcher.ranked(candidates, target)
            if (requireSharedArtist) {
                matches = matches.filter { TrackMatcher.sharesArtist(target.artist, it.artist) }
            }
            // JioSaavn can return different audio under the same title and artist on
            // different releases. With no album on the requested track there is no
            // honest way to choose between those rows; duration is not enough when
            // the wrong recording is only a second away. Treat it as this source
            // missing and retain the known-correct fallback.
            if (source.kind == SourceKind.JIOSAAVN &&
                TrackMatcher.hasConflictingAlbums(matches, target)
            ) {
                val canonical = TrackMatcher.uniquelyMostCreditedCloseMatch(matches, target)
                if (canonical == null) {
                    DebugLog.w(
                        "${source.displayName} returned conflicting albums for '${target.title}'; " +
                            "refusing to guess",
                    )
                    continue
                }
                DebugLog.d(
                    "${source.displayName} resolved conflicting albums for '${target.title}' " +
                        "using the uniquely fullest credit: '${canonical.artist}'",
                )
                matches = listOf(canonical)
            }
            // The extra bar for standing in for one specific recording: the replacement
            // has to be the same *length* within the listener's configured slack. A title and an artist
            // can agree across two different edits of a song; a runtime that agrees
            // this closely is one recording, and nothing else is worth cutting a
            // listener's audio for — or filing on their device under the name of the
            // track they asked for.
            if (strictLength) {
                matches = matches.filter { TrackMatcher.withinSeconds(it, target, upgradeLengthSlackSeconds()) }
            }
            if (matches.isEmpty()) continue
            return streamBest(source, matches, target, request, allowLossless)
        }
        return null
    }

    /**
     * The matching rows, in the order they are worth opening.
     *
     * Two rules, and the order of them is the point:
     *
     *  1. **Length decides which recording, first.** When any candidate agrees with
     *     the runtime being asked for within the configured slack, only the
     *     candidates that agree are eligible at all. A catalogue holding the track
     *     under its right title and artist can still be holding a different *cut* of
     *     it — a DJ edit on a compilation, an extended mix — and the runtime is what
     *     separates those when nothing in the title does. If nothing agrees, nothing
     *     is excluded: the runtimes are simply not informative here and the score
     *     stands alone.
     *
     *  2. **Quality decides between equals, second.** Among rows that are the same
     *     recording, one advertising a lossless copy is the better place to ask. This
     *     was doing that job *first*, which is how a 185-second
     *     "Punjabi Dj Holi songs" cut beat the 180-second album track on the strength
     *     of the word `flac` in its listing. A declared tier is a reason to prefer
     *     one copy of a recording over another; it is not a reason to play a
     *     different recording.
     */
    internal fun preferred(
        matches: List<Song>,
        target: TrackMatcher.Target,
        wantsLossless: Boolean,
    ): List<Song> {
        val sameLength = matches.filter { TrackMatcher.withinSeconds(it, target, SAME_RECORDING_SEC) }
        val eligible = sameLength.ifEmpty { matches }
        if (!wantsLossless) return eligible
        // Stable, so the confidence order TrackMatcher.ranked produced survives
        // inside each tier.
        return eligible.sortedByDescending { it.sourceQuality == LOSSLESS_QUALITY }
    }

    private suspend fun streamBest(
        source: MusicSource,
        matches: List<Song>,
        target: TrackMatcher.Target,
        request: StreamRequest,
        allowLossless: Boolean,
    ): SourceStream? {
        val wantsLossless = request is StreamRequest.Lossless
        val ordered = preferred(matches, target, wantsLossless)
        var settleFor: SourceStream? = null
        for (match in ordered.take(STREAM_ATTEMPTS)) {
            val trackId = SourceRegistry.parseTrackKey(match.videoId)?.second ?: match.videoId
            val opened = attempt(source) { source.stream(trackId, request) } ?: continue
            // The row this URL came from knows how long the recording is; the URL
            // itself doesn't. Carried along so a caller swapping this into a track
            // already playing can check it.
            val stream = StreamVerification.verify(opened.copy(
                durationSec = TrackMatcher.secondsOf(match.durationText),
                sourceConfigId = source.configId,
            )) ?: continue
            val served = stream.format
            if (rejectUnsupportedNativeStream(source, stream, match.title)) continue
            if (!allowLossless && served.isLossless == true) {
                DebugLog.d("${source.displayName} offered lossless for '${match.title}' on a route that cannot carry it; trying another match")
                continue
            }
            if (!wantsLossless || served.isLossless == true || served.isDolbyAtmos || served.statesNothingLossy) {
                DebugLog.d(
                    "${source.displayName} matched '${match.title}' by '${match.artist}' " +
                        "at ${served.summary}",
                )
                return stream
            }
            SourceResolutionReport.record("provider_lossy")
            DebugLog.d(
                "${source.displayName} offered ${served.summary} for '${match.title}'; looking further",
            )
            // The floor is the *best* of what was refused, not the first of it. These
            // arrive in match order, which has nothing to do with quality: a 320kbps
            // AAC and a 128kbps MP3 are both rejections, and which one the listener
            // ends up on if nothing better exists should not come down to which
            // catalogue happened to be asked first.
            settleFor = betterOf(settleFor, stream.copy(belowRequest = true))
        }
        if (settleFor == null) SourceResolutionReport.record("no_match")
        return settleFor
    }

    /** Rejects a known unsupported codec before it can become the chosen stream. */
    private fun rejectUnsupportedNativeStream(
        source: MusicSource,
        stream: SourceStream,
        title: String,
    ): Boolean {
        if (!stream.format.isKnownUnsupportedByNativeDecoder ||
            PlaybackCodecCapabilities.canRenderDolby(stream.format.codec, stream.headers)) return false
        DebugLog.d(
            "${source.displayName} offered ${stream.format.summary} for '$title', " +
                "which the native decoder cannot play; trying another source",
        )
        return true
    }

    /**
     * Whether [candidate] is a better rendition than [current], by codec first and
     * bitrate second. A null [current] is beaten by anything.
     *
     * The one rule for ranking two copies of the same recording, kept in one place
     * because three different walks now need it: [streamBest] choosing between rows
     * inside a source, [bestAcross] choosing between sources, and [upgradeFor]
     * choosing what to cut into a track that is already playing.
     *
     * Note that this is *not* [worthSwapping]. This asks which of two streams is
     * better; that one asks whether the difference is worth a break in the audio,
     * which is a much higher bar and only meaningful mid-playback.
     */
    internal fun isBetter(candidate: StreamFormat, current: StreamFormat?): Boolean {
        if (current == null) return true
        // Immersive first, and ahead of lossless rather than behind it. This used to
        // sit *after* the lossless test, which made it unreachable in the only
        // comparison it exists for: an Atmos stream is E-AC-3 and so answers
        // `isLossless == false`, so a FLAC won on the line above and the Atmos line
        // below never ran. A track offered as both then played as the FLAC no matter
        // what the Atmos setting said — and worse, a mid-playback upgrade would cut
        // the FLAC in over an Atmos stream already playing.
        if (candidate.isDolbyAtmos != current.isDolbyAtmos) return candidate.isDolbyAtmos
        if (candidate.isLossless != current.isLossless) return candidate.isLossless == true
        if (candidate.isLossless == true) {
            // Compressed FLAC/ALAC bitrate measures compression, not fidelity.
            val depth = candidate.bitDepth ?: 0
            val rate = candidate.sampleRateHz ?: 0
            val oldDepth = current.bitDepth ?: 0
            val oldRate = current.sampleRateHz ?: 0
            return depth >= oldDepth && rate >= oldRate && (depth > oldDepth || rate > oldRate)
        }
        // Cross-codec bitrates are not a perceptual quality scale. Retain source
        // preference rather than inventing an AAC/Opus conversion factor.
        if (candidate.codecFamily == null || candidate.codecFamily != current.codecFamily) return false
        return (candidate.kbps ?: 0) > (current.kbps ?: 0)
    }

    /** The higher-quality of two streams — see [isBetter]. */
    private fun betterOf(current: SourceStream?, candidate: SourceStream): SourceStream =
        if (current == null || isBetter(candidate.format, current.format)) candidate else current

    /**
     * Whether a format has said nothing that rules lossless out.
     *
     * Unknown is not the same as lossy, and a source that reports neither a codec
     * nor a bitrate has not failed the request — it has declined to describe it, and
     * the decoder will say soon enough. A stated bitrate is different: nothing states
     * a bitrate for a FLAC.
     */
    private val StreamFormat.statesNothingLossy: Boolean
        get() = isLossless == null && kbps == null

    /**
     * Runs [block], turning any failure into null and a log line.
     *
     * Every call into a source is a call to somebody else's server, and a source
     * that throws must cost the *source* its turn, not the track its playback.
     * Cancellation is re-thrown: that is the caller giving up, and swallowing it would
     * keep walking sources for a track nobody is waiting for any more.
     */
    private suspend fun <T> attempt(source: MusicSource, block: suspend () -> T): T? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        DebugLog.w("${source.displayName} failed: ${e::class.simpleName}: ${e.message}")
        null
    }

    // ── Constants ───────────────────────────────────────────────────────────

    /**
     * How many answers per query are worth weighing.
     *
     * Wider than it needs to be for a well-behaved catalogue, because
     * [TrackMatcher.ranked] scores the whole list rather than taking the first
     * acceptable row: a backend that ranks the karaoke version, three covers and a
     * sped-up edit above the album cut still has the album cut in here somewhere, and
     * the extra rows cost one response body, not one request.
     */
    private const val MATCH_CANDIDATES = 15

    /**
     * How many of the matching rows are worth actually opening.
     *
     * Each one is a round trip to a stream endpoint, so this is the budget for "the
     * first copy wasn't the quality asked for" — enough to get past a source whose
     * lossless backend is down, not enough to spend a listener's patience walking a
     * whole result list.
     */
    private const val STREAM_ATTEMPTS = 3

    /**
     * How far a replacement's runtime may sit from the playing track's before it
     * stops being the same recording.
     *
     * Far tighter than [TrackMatcher]'s own tolerance, and deliberately: that one
     * is deciding what to play, this one is deciding whether to cut the audio a
     * listener is in the middle of.
     */
    /**
     * How close two runtimes have to be to be the same cut of a song.
     *
     * Wide enough for a catalogue rounding, or a second of lead-in trimmed
     * differently. Narrow enough to separate the album track from the DJ edit sitting
     * next to it in the same search results under the same name.
     */
    private const val SAME_RECORDING_SEC = 3

    /**
     * The top of YouTube's own AAC ladder, and so the bar a lossy source has to clear
     * to be worth keeping as a file.
     *
     * Not a measurement of any one track. Most of the catalogue offers itag 140 at
     * 128kbps and a signed-in account reaches itag 141 at 256, and which of those a
     * given track has cannot be known without resolving it — a full player walk,
     * spent to answer a question about a stream we may then not use. So the bar is
     * the *best* YouTube could turn out to have.
     */
    private const val YOUTUBE_BEST_AAC_KBPS = 256

    /**
     * How many kbps a lossy stream has to gain before it earns a seam in the audio.
     *
     * Sized off the two rates this actually decides between: YouTube's Opus, which
     * lands around 160, and a lossy source tier, which is 320. Anything much smaller
     * would start firing on differences no one can hear.
     */
    private const val UPGRADE_MIN_GAIN_KBPS = 96

    /** What a row says when it is offering the bit-exact copy. */
    private const val LOSSLESS_QUALITY = "LOSSLESS"
}
