import Foundation
import BitChordShared

/// How far back a Replay reaches — same three chips as upstream `ReplayPeriod`.
/// Named separately from the UI's `ReplayPeriod` so both can compile until Replay
/// binds `summary(period:)`.
enum ListeningPeriod: String, CaseIterable, Sendable, Identifiable {
    case thisWeek
    case thisMonth
    case thisYear
    case allTime

    var id: String { rawValue }

    var chip: String {
        switch self {
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        }
    }

    func covers(month: String, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        switch self {
        case .allTime: return true
        case .thisWeek:
            // A week can straddle two months, so both are read: the file of the
            // month the week started in, and the current one.
            guard let start = Self.weekStart(now) else { return month == ListeningStore.monthKey(now) }
            return month == ListeningStore.monthKey(start) || month == ListeningStore.monthKey(now)
        case .thisYear:
            return month.hasPrefix(String(format: "%04d", cal.component(.year, from: now)))
        case .thisMonth:
            return month == ListeningStore.monthKey(now)
        }
    }

    /// The start of the calendar week `now` falls in — Monday in most locales.
    static func weekStart(_ now: Date = Date()) -> Date? {
        Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start
    }

    func label(now: Date = Date()) -> String {
        let cal = Calendar.current
        switch self {
        case .thisWeek:
            guard let start = Self.weekStart(now) else { return "This Week" }
            let fmt = DateFormatter()
            fmt.dateFormat = "d MMM"
            return "\(fmt.string(from: start)) – \(fmt.string(from: now))"
        case .thisMonth:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM yyyy"
            return fmt.string(from: now)
        case .thisYear:
            return String(cal.component(.year, from: now))
        case .allTime:
            return "All Time"
        }
    }
}

/// Local listening aggregates for Replay — monthly JSON buckets, same idea as
/// upstream `ListeningStats`: add on the way in, merge a handful of months
/// when Replay asks. The open month is in memory; the rest live on disk.
/// Not `@MainActor` so ReplayView's static `load` can call `summary(period:)`
/// without a hop — samples still come from the playback MainActor.
final class ListeningStore {
    static let shared = ListeningStore()

    private let v1Key = "listening_stats_v1"
    private var currentId: String?
    private var lastSampleAt: Date?
    private var playedThisTrack: TimeInterval = 0
    private var playCounted = false

    /// Persistence, off the main thread and coalesced.
    ///
    /// [`onSample`] is driven by the playback tick, four times a second, and it
    /// used to end in [`persist`] — which is two JSON encodes, an atomic file
    /// write with a remove/move pair, and a `UserDefaults` encode, all on the
    /// main thread. That was the app's largest source of main-thread I/O while
    /// music played, and it is felt twice over: the UI hitches, and the audio
    /// decoder — which used to run in the same priority band — loses the CPU it
    /// needs to keep the output ring fed.
    ///
    /// Updating the in-memory model is cheap and stays where it is. Encoding and
    /// writing it is not, so that half moves to a serial background queue, and
    /// bursts are coalesced: only the newest snapshot is written, and a write
    /// that lands while another is queued replaces it rather than joining a
    /// queue. State below is main-thread only; the writer hops back to clear it.
    private let persistQueue = DispatchQueue(
        label: "app.bitchord.BitChord.listening-persist",
        qos: .utility
    )
    /// Fastest the store will rewrite the disk while a track is playing. The
    /// model is in memory regardless, so the exposure is at most this much
    /// listening time if the app is killed outright.
    private let persistInterval: TimeInterval = 2
    private var pendingPersist: (month: StoredBucket, bucket: Bucket)?
    private var persistRunning = false
    private var lastPersistAt = Date.distantPast
    /// Filled by Replay after `ArtistFacts.warmup` so genre ranking is MainActor-cheap.
    var knownGenres: [String: [String]] = [:]

    /// v1 all-time mirror so existing ReplayView / Settings backup still decode
    /// `listening_stats_v1` until the UI worker binds `summary(period:)`.
    struct Bucket: Codable {
        var tracks: [String: Track] = [:]
        var days: [String: Double] = [:]
    }

    struct Track: Codable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var album: String?
        var albumId: String?
        var artistId: String?
        var art: String?
        var ms: Double
        var plays: Int
        var last: Double?
    }

    struct NameEntry: Codable {
        var name: String
        var sub: String?
        var art: String?
        var id: String?
        var ms: Double
        var plays: Int
    }

    /// One calendar month on disk — upstream `StoredBucket`.
    struct StoredBucket: Codable {
        var version: Int = 1
        var month: String
        var tracks: [Track] = []
        var artists: [NameEntry] = []
        var albums: [NameEntry] = []
        var hours: [Double] = Array(repeating: 0, count: 24)
        var days: [Int: Double] = [:]
        /// Day key ("2026-10-23") → that day's tracks. Optional so a file
        /// written before F12 still decodes.
        var dayTracks: [String: [Track]]? = nil
        /// Day key → that day's listening by hour (24 values, ms), so the week
        /// has an hour histogram of its own. Optional for the same reason.
        var dayHours: [String: [Double]]? = nil
    }

    private struct ExportEnvelope: Codable {
        var version: Int = 2
        var months: [StoredBucket]
    }

    private struct OpenBucket {
        var key: String
        var tracks: [String: Track] = [:]
        var artists: [String: NameEntry] = [:]
        var albums: [String: NameEntry] = [:]
        var hours: [Double] = Array(repeating: 0, count: 24)
        var days: [Int: Double] = [:]
        /// Per-day track totals, for the week Replay. Only recent days are kept.
        var dayTracks: [String: [Track]] = [:]
        var dayHours: [String: [Double]] = [:]

        func snapshot() -> StoredBucket {
            StoredBucket(
                month: key,
                tracks: Array(tracks.values),
                artists: Array(artists.values),
                albums: Array(albums.values),
                hours: hours,
                days: days,
                dayTracks: dayTracks,
                dayHours: dayHours
            )
        }

        static func from(_ stored: StoredBucket) -> OpenBucket {
            var hours = Array(repeating: 0.0, count: 24)
            for (i, value) in stored.hours.prefix(24).enumerated() { hours[i] = value }
            var artists: [String: NameEntry] = [:]
            for entry in stored.artists {
                let lead = ListeningStore.primaryArtist(entry.name) ?? entry.name
                let key = lead.lowercased()
                if var existing = artists[key] {
                    existing.ms += entry.ms
                    existing.plays += entry.plays
                    if existing.art == nil { existing.art = entry.art }
                    if existing.id == nil { existing.id = entry.id }
                    artists[key] = existing
                } else {
                    artists[key] = NameEntry(
                        name: lead, sub: entry.sub, art: entry.art,
                        id: entry.id, ms: entry.ms, plays: entry.plays
                    )
                }
            }
            var albums: [String: NameEntry] = [:]
            for entry in stored.albums {
                let key = ListeningStore.albumKey(entry.name, entry.sub ?? "")
                if var existing = albums[key] {
                    existing.ms += entry.ms
                    existing.plays += entry.plays
                    if existing.art == nil { existing.art = entry.art }
                    if existing.id == nil { existing.id = entry.id }
                    albums[key] = existing
                } else {
                    albums[key] = entry
                }
            }
            return OpenBucket(
                key: stored.month,
                tracks: Dictionary(uniqueKeysWithValues: stored.tracks.map { ($0.id, $0) }),
                artists: artists,
                albums: albums,
                hours: hours,
                days: stored.days,
                dayTracks: stored.dayTracks ?? [:],
                dayHours: stored.dayHours ?? [:]
            )
        }
    }

    private var open: OpenBucket
    /// All-time v1 mirror (tracks + ISO day keys).
    private var bucket: Bucket

    private static let keepMonths = 36
    private static let maxTracks = 600
    private static let maxNames = 400

    init() {
        let nowKey = Self.monthKey()
        if let stored = Self.readMonth(nowKey) {
            open = OpenBucket.from(stored)
        } else {
            open = OpenBucket(key: nowKey)
        }
        if let data = UserDefaults.standard.data(forKey: v1Key),
           let decoded = try? JSONDecoder().decode(Bucket.self, from: data) {
            bucket = decoded
        } else {
            bucket = Bucket()
        }
        migrateV1IfNeeded()
    }

    func onSample(
        id: String, title: String, artist: String, album: String?,
        albumId: String?, artistId: String?, art: String?, duration: Double,
        at now: Date = Date()
    ) {
        if id != currentId {
            currentId = id
            lastSampleAt = now
            playedThisTrack = 0
            playCounted = false
            return
        }
        guard let last = lastSampleAt else { lastSampleAt = now; return }
        let step = min(now.timeIntervalSince(last), 4)
        lastSampleAt = now
        guard step > 0 else { return }
        playedThisTrack += step
        let length = duration > 0 ? duration : 0
        let threshold = length > 0 ? min(max(length / 2, 30), 240) : 30
        let counts = !playCounted && playedThisTrack >= threshold
        if counts { playCounted = true }
        let playedMs = step * 1000
        record(
            id: id, title: title, artist: artist, album: album,
            albumId: albumId, artistId: artistId, art: art,
            playedMs: playedMs, countsAsPlay: counts, at: now
        )
        persist()
    }

    func onStopped() {
        currentId = nil
        lastSampleAt = nil
        persist()
    }

    func persist() {
        #if DEBUG
        if Self.persistenceDisabled { return }
        #endif
        pendingPersist = (open.snapshot(), bucket)
        schedulePersist()
    }

    /// Starts a writer unless one is already running or the interval has not
    /// elapsed. The snapshot taken in `persist` is always the newest, so a
    /// burst of samples collapses into one write of the final state — and the
    /// write that lands while another is queued replaces it instead of queueing
    /// behind it.
    private func schedulePersist() {
        guard !persistRunning, let snapshot = pendingPersist else { return }
        pendingPersist = nil
        persistRunning = true
        let wait = max(0, persistInterval - Date().timeIntervalSince(lastPersistAt))
        persistQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.writeMonth(snapshot.month)
            if let data = try? JSONEncoder().encode(snapshot.bucket) {
                UserDefaults.standard.set(data, forKey: self.v1Key)
            }
            DispatchQueue.main.async {
                self.lastPersistAt = Date()
                self.persistRunning = false
                // Anything recorded while this ran still has to land.
                self.schedulePersist()
            }
        }
    }

    /// All-time Replay — existing call sites keep working.
    func summary(includeGenres: Bool = true) -> ReplaySummary {
        summary(period: .allTime, includeGenres: includeGenres)
    }

    /// Period-filtered top songs / artists / albums / genres.
    func summary(
        period: ListeningPeriod,
        includeGenres: Bool = true,
        now: Date = Date()
    ) -> ReplaySummary {
        persist()
        if period == .thisWeek { return weekSummary(includeGenres: includeGenres, now: now) }
        let months = collected(period: period, now: now)
        var tracks: [String: Track] = [:]
        var artists: [String: NameEntry] = [:]
        var albums: [String: NameEntry] = [:]
        var hours = Array(repeating: 0.0, count: 24)
        var days: [String: Double] = [:]
        var earliest: String?

        for month in months {
            for entry in month.tracks {
                if var existing = tracks[entry.id] {
                    existing.ms += entry.ms
                    existing.plays += entry.plays
                    if existing.album == nil { existing.album = entry.album }
                    if existing.albumId == nil { existing.albumId = entry.albumId }
                    if existing.artistId == nil { existing.artistId = entry.artistId }
                    if existing.art == nil { existing.art = entry.art }
                    tracks[entry.id] = existing
                } else {
                    tracks[entry.id] = entry
                }
            }
            for entry in month.artists {
                let lead = Self.primaryArtist(entry.name) ?? entry.name
                let key = lead.lowercased()
                if var existing = artists[key] {
                    existing.ms += entry.ms
                    existing.plays += entry.plays
                    if existing.art == nil { existing.art = entry.art }
                    if existing.id == nil { existing.id = entry.id }
                    artists[key] = existing
                } else {
                    artists[key] = NameEntry(
                        name: lead, sub: entry.sub, art: entry.art,
                        id: entry.id, ms: entry.ms, plays: entry.plays
                    )
                }
            }
            for entry in month.albums {
                let key = Self.albumKey(entry.name, entry.sub ?? "")
                if var existing = albums[key] {
                    existing.ms += entry.ms
                    existing.plays += entry.plays
                    if existing.art == nil { existing.art = entry.art }
                    if existing.id == nil { existing.id = entry.id }
                    albums[key] = existing
                } else {
                    albums[key] = entry
                }
            }
            for (i, value) in month.hours.prefix(24).enumerated() {
                hours[i] += value
            }
            for (day, ms) in month.days {
                let iso = "\(month.month)-\(String(format: "%02d", day))"
                days[iso, default: 0] += ms
            }
            if earliest == nil || month.month < earliest! { earliest = month.month }
        }

        return assemble(
            tracks: tracks,
            artists: artists,
            albums: albums,
            hours: hours,
            days: days,
            earliest: earliest,
            period: period,
            includeGenres: includeGenres,
            now: now
        )
    }


    /// The shared tail of every period: rank what was collected and describe it.
    ///
    /// Split out so the week can be built from its per-day rows and still be
    /// ranked, labelled and described by exactly the same code as a month or a
    /// year.
    private func assemble(
        tracks source: [String: Track],
        artists sourceArtists: [String: NameEntry],
        albums sourceAlbums: [String: NameEntry],
        hours: [Double],
        days: [String: Double],
        earliest: String?,
        period: ListeningPeriod,
        includeGenres: Bool,
        now: Date
    ) -> ReplaySummary {
        let tracks = source
        var artists = sourceArtists
        var albums = sourceAlbums
        if artists.isEmpty || albums.isEmpty {
            for t in tracks.values {
                if artists.isEmpty {
                    let lead = Self.primaryArtist(t.artist) ?? t.artist
                    let key = lead.lowercased()
                    var row = artists[key] ?? NameEntry(name: lead, sub: nil, art: t.art, id: t.artistId, ms: 0, plays: 0)
                    row.ms += t.ms
                    row.plays += t.plays
                    artists[key] = row
                }
                if albums.isEmpty, let album = t.album, !album.isEmpty {
                    let key = Self.albumKey(album, t.artist)
                    var row = albums[key] ?? NameEntry(name: album, sub: t.artist, art: t.art, id: t.albumId, ms: 0, plays: 0)
                    row.ms += t.ms
                    row.plays += t.plays
                    albums[key] = row
                }
            }
        }

        let withGenres = includeGenres && ArtistFacts.genresEnabled
        var genres: [Ranked] = []
        if withGenres {
            var genreMs: [String: Double] = [:]
            for artist in artists.values {
                for genre in (knownGenres[artist.name] ?? []) {
                    genreMs[genre, default: 0] += artist.ms
                }
            }
            genres = genreMs.map { Ranked(name: $0.key, ms: $0.value, browseId: nil) }
                .sorted { $0.ms > $1.ms }.prefix(10).map { $0 }
        }

        let songs = tracks.values.sorted { $0.ms > $1.ms }
        let busiest = days.max { $0.value < $1.value }
        return ReplaySummary(
            totalMs: tracks.values.reduce(0) { $0 + $1.ms },
            totalPlays: tracks.values.reduce(0) { $0 + $1.plays },
            songs: Array(songs.prefix(10)),
            artists: artists.values.map {
                Ranked(name: $0.name, ms: $0.ms, browseId: $0.id, plays: $0.plays,
                       sub: $0.sub, art: $0.art)
            }
                .sorted { $0.ms > $1.ms }.prefix(10).map { $0 },
            albums: albums.values.map {
                Ranked(name: $0.name, ms: $0.ms, browseId: $0.id, plays: $0.plays,
                       sub: $0.sub, art: $0.art)
            }
                .sorted { $0.ms > $1.ms }.prefix(10).map { $0 },
            genres: genres,
            busiestDay: busiest.map { $0.key },
            busiestDayMs: busiest?.value ?? 0,
            hourOfDay: hours,
            period: period,
            label: period.label(now: now),
            distinctSongs: tracks.count,
            distinctArtists: artists.count,
            distinctAlbums: albums.count,
            since: earliest
        )
    }

    /// Replay for the calendar week so far.
    ///
    /// Built from the per-day rows rather than the month totals, because a week
    /// begins mid-month and is not a subset of any one bucket. Artists and albums
    /// are derived from the week's tracks by the same rules the month aggregation
    /// uses, and the hour histogram is the sum of the week's per-day hours (days
    /// recorded before those were kept contribute none).
    private func weekSummary(includeGenres: Bool, now: Date) -> ReplaySummary {
        let cal = Calendar.current
        let start = ListeningPeriod.weekStart(now) ?? now
        let firstDay = cal.startOfDay(for: start)

        var tracks: [String: Track] = [:]
        var artists: [String: NameEntry] = [:]
        var albums: [String: NameEntry] = [:]
        var days: [String: Double] = [:]
        var hours = Array(repeating: 0.0, count: 24)

        for month in collected(period: .thisWeek, now: now) {
            for (day, values) in month.dayHours ?? [:] {
                guard let date = Self.date(fromDayKey: day), date >= firstDay, date <= now else { continue }
                for (i, value) in values.prefix(24).enumerated() { hours[i] += value }
            }
            for (day, entries) in month.dayTracks ?? [:] {
                guard let date = Self.date(fromDayKey: day), date >= firstDay, date <= now else { continue }
                for entry in entries {
                    if var existing = tracks[entry.id] {
                        existing.ms += entry.ms
                        existing.plays += entry.plays
                        if existing.art == nil { existing.art = entry.art }
                        tracks[entry.id] = existing
                    } else {
                        tracks[entry.id] = entry
                    }
                    if let lead = Self.primaryArtist(entry.artist) {
                        let key = lead.lowercased()
                        var row = artists[key] ?? NameEntry(
                            name: lead, sub: nil, art: entry.art, id: entry.artistId,
                            ms: 0, plays: 0
                        )
                        row.ms += entry.ms
                        row.plays += entry.plays
                        if row.id == nil { row.id = entry.artistId }
                        if row.art == nil { row.art = entry.art }
                        artists[key] = row
                    }
                    if let album = entry.album, !album.isEmpty {
                        let key = Self.albumKey(album, entry.artist)
                        var row = albums[key] ?? NameEntry(
                            name: album, sub: entry.artist, art: entry.art, id: entry.albumId,
                            ms: 0, plays: 0
                        )
                        row.ms += entry.ms
                        row.plays += entry.plays
                        if row.id == nil { row.id = entry.albumId }
                        if row.art == nil { row.art = entry.art }
                        albums[key] = row
                    }
                    days[day, default: 0] += entry.ms
                }
            }
        }

        return assemble(
            tracks: tracks,
            artists: artists,
            albums: albums,
            hours: hours,
            days: days,
            earliest: ListeningStore.monthKey(start),
            period: .thisWeek,
            includeGenres: includeGenres,
            now: now
        )
    }

    /// Names for the playback cache, which stores audio and a hash rather than
    /// titles. The newest play wins, because a track's name can be corrected and
    /// the cache is keyed by the audio, not by the name in force when it landed.
    /// A read-only snapshot for background cache migration. It must not call
    /// persist() or touch the live playback counters from a background executor.
    static func savedTrackMetadata() -> [String: Track] {
        var out: [String: Track] = [:]
        for key in monthFiles() {
            for track in readMonth(key)?.tracks ?? [] {
                if let previous = out[track.id], (previous.last ?? 0) > (track.last ?? 0) { continue }
                out[track.id] = track
            }
        }
        return out
    }

    func trackMetadata() -> [String: Track] {
        persist()
        var out: [String: Track] = [:]
        for month in collected(period: .allTime) {
            for track in month.tracks {
                if let existing = out[track.id], (existing.last ?? 0) > (track.last ?? 0) { continue }
                out[track.id] = track
            }
        }
        return out
    }

    /// Latest recorded play time for each track, in milliseconds since epoch.
    /// Replay's display summary intentionally keeps only its ten top songs;
    /// Autoplay needs the full recency map so repeats outside that short list
    /// still count as recently heard.
    func lastPlayedByTrack() -> [String: Double] {
        persist()
        var result: [String: Double] = [:]
        for month in collected(period: .allTime) {
            for track in month.tracks {
                guard let last = track.last else { continue }
                result[track.id] = max(result[track.id] ?? 0, last)
            }
        }
        return result
    }

    func exportJSON() -> Data? {
        persist()
        let months = collected(period: .allTime)
        return try? JSONEncoder().encode(ExportEnvelope(months: months))
    }

    func importJSON(_ data: Data) {
        if let envelope = try? JSONDecoder().decode(ExportEnvelope.self, from: data),
           envelope.version >= 2 {
            importMonths(envelope.months)
            return
        }
        if let months = try? JSONDecoder().decode([StoredBucket].self, from: data),
           months.contains(where: { !$0.month.isEmpty }) {
            importMonths(months)
            return
        }
        if let decoded = try? JSONDecoder().decode(Bucket.self, from: data) {
            bucket = decoded
            importMonths(Self.monthsFromV1(decoded))
        }
    }

    // MARK: - Record

    private func record(
        id: String, title: String, artist: String, album: String?,
        albumId: String?, artistId: String?, art: String?,
        playedMs: Double, countsAsPlay: Bool, at: Date
    ) {
        rolloverIfNeeded(at)
        var track = open.tracks[id] ?? Track(
            id: id, title: title, artist: artist, album: album,
            albumId: albumId, artistId: artistId, art: art, ms: 0, plays: 0, last: nil
        )
        track.title = title
        track.artist = artist
        if track.album == nil { track.album = album }
        if track.albumId == nil { track.albumId = albumId }
        if track.artistId == nil { track.artistId = artistId }
        if track.art == nil { track.art = art }
        track.ms += playedMs
        if countsAsPlay { track.plays += 1 }
        track.last = at.timeIntervalSince1970 * 1000
        open.tracks[id] = track

        if let lead = Self.primaryArtist(artist) {
            let key = lead.lowercased()
            var row = open.artists[key] ?? NameEntry(name: lead, sub: nil, art: art, id: artistId, ms: 0, plays: 0)
            row.ms += playedMs
            if countsAsPlay { row.plays += 1 }
            if row.id == nil { row.id = artistId }
            if row.art == nil { row.art = art }
            open.artists[key] = row
        }

        if let album, !album.isEmpty {
            let key = Self.albumKey(album, artist)
            var row = open.albums[key] ?? NameEntry(name: album, sub: artist, art: art, id: albumId, ms: 0, plays: 0)
            row.ms += playedMs
            if countsAsPlay { row.plays += 1 }
            if row.id == nil { row.id = albumId }
            if row.art == nil { row.art = art }
            open.albums[key] = row
        }

        // The week's summary is built from the days themselves, because a week
        // crosses the month boundary the other buckets are keyed on.
        let dayKey = Self.isoDay(at)
        var dayTracks = open.dayTracks[dayKey] ?? []
        if let index = dayTracks.firstIndex(where: { $0.id == id }) {
            dayTracks[index].ms += playedMs
            if countsAsPlay { dayTracks[index].plays += 1 }
            dayTracks[index].last = track.last
            dayTracks[index].title = track.title
            dayTracks[index].artist = track.artist
        } else {
            // Only what this call listened to. `track` is the month's running
            // total, so copying it gave a day the whole month's minutes the
            // moment a second day started.
            dayTracks.append(Track(
                id: id, title: title, artist: artist, album: album,
                albumId: albumId, artistId: artistId, art: art,
                ms: playedMs, plays: countsAsPlay ? 1 : 0, last: track.last
            ))
        }
        open.dayTracks[dayKey] = dayTracks

        let hour = Calendar.current.component(.hour, from: at)
        if hour >= 0 && hour < 24 {
            open.hours[hour] += playedMs
            var dayHours = open.dayHours[dayKey] ?? Array(repeating: 0, count: 24)
            dayHours[hour] += playedMs
            open.dayHours[dayKey] = dayHours
        }
        let day = Calendar.current.component(.day, from: at)
        open.days[day, default: 0] += playedMs
        pruneOpen()

        // All-time v1 mirror for ReplayView until it binds period summaries.
        var v1 = bucket.tracks[id] ?? Track(
            id: id, title: title, artist: artist, album: album,
            albumId: albumId, artistId: artistId, art: art, ms: 0, plays: 0, last: nil
        )
        v1.title = title
        v1.artist = artist
        if let album { v1.album = album }
        v1.ms += playedMs
        if countsAsPlay { v1.plays += 1 }
        bucket.tracks[id] = v1
        let iso = Self.isoDay(at)
        bucket.days[iso, default: 0] += playedMs
    }

    private func rolloverIfNeeded(_ at: Date) {
        let key = Self.monthKey(at)
        guard open.key != key else { return }
        writeMonth(open.snapshot())
        open = Self.readMonth(key).map(OpenBucket.from) ?? OpenBucket(key: key)
        pruneFolder()
    }

    /// How many days of per-day tracks a month bucket keeps. The week needs a
    /// fortnight at most; a little more costs nothing and covers a stale clock.
    private static let keptDays = 21

    private func pruneOpen() {
        if open.dayTracks.count > Self.keptDays {
            let keep = open.dayTracks.keys.sorted().suffix(Self.keptDays)
            open.dayTracks = open.dayTracks.filter { keep.contains($0.key) }
        }
        if open.dayHours.count > Self.keptDays {
            let keep = open.dayHours.keys.sorted().suffix(Self.keptDays)
            open.dayHours = open.dayHours.filter { keep.contains($0.key) }
        }
        if open.tracks.count > Self.maxTracks {
            let drop = open.tracks.values.sorted { $0.ms < $1.ms }.prefix(open.tracks.count - Self.maxTracks)
            drop.forEach { open.tracks.removeValue(forKey: $0.id) }
        }
        if open.artists.count > Self.maxNames {
            let drop = open.artists.sorted { $0.value.ms < $1.value.ms }.prefix(open.artists.count - Self.maxNames)
            drop.forEach { open.artists.removeValue(forKey: $0.key) }
        }
        if open.albums.count > Self.maxNames {
            let drop = open.albums.sorted { $0.value.ms < $1.value.ms }.prefix(open.albums.count - Self.maxNames)
            drop.forEach { open.albums.removeValue(forKey: $0.key) }
        }
    }

    // MARK: - Months on disk

    private func collected(period: ListeningPeriod, now: Date = Date()) -> [StoredBucket] {
        var keys = Set(Self.monthFiles())
        keys.insert(open.key)
        return keys.sorted()
            .filter { period.covers(month: $0, now: now) }
            .compactMap { key in
                if key == open.key { return open.snapshot() }
                return Self.readMonth(key)
            }
    }

    private func importMonths(_ months: [StoredBucket]) {
        Self.ensureFolder()
        if let existing = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var rebuilt = Bucket()
        for month in months {
            guard month.month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil else { continue }
            writeMonth(month)
            for track in month.tracks {
                if var existing = rebuilt.tracks[track.id] {
                    existing.ms += track.ms
                    existing.plays += track.plays
                    rebuilt.tracks[track.id] = existing
                } else {
                    rebuilt.tracks[track.id] = track
                }
            }
            for (day, ms) in month.days {
                rebuilt.days["\(month.month)-\(String(format: "%02d", day))", default: 0] += ms
            }
        }
        bucket = rebuilt
        let nowKey = Self.monthKey()
        open = Self.readMonth(nowKey).map(OpenBucket.from) ?? OpenBucket(key: nowKey)
        persist()
    }

    private func migrateV1IfNeeded() {
        guard Self.monthFiles().isEmpty, !bucket.tracks.isEmpty || !bucket.days.isEmpty else { return }
        importMonths(Self.monthsFromV1(bucket))
    }

    private static func monthsFromV1(_ v1: Bucket) -> [StoredBucket] {
        var byMonth: [String: StoredBucket] = [:]
        for (iso, ms) in v1.days {
            let parts = iso.split(separator: "-")
            guard parts.count >= 2 else { continue }
            let key = "\(parts[0])-\(parts[1])"
            let day = Int(parts.count >= 3 ? parts[2] : "1") ?? 1
            var month = byMonth[key] ?? StoredBucket(month: key)
            month.days[day, default: 0] += ms
            byMonth[key] = month
        }
        let latest = byMonth.keys.sorted().last ?? monthKey()
        var host = byMonth[latest] ?? StoredBucket(month: latest)
        host.tracks = Array(v1.tracks.values)
        byMonth[latest] = host
        return Array(byMonth.values)
    }

    private func writeMonth(_ stored: StoredBucket) {
        Self.ensureFolder()
        let dest = Self.folder.appendingPathComponent("\(stored.month).json")
        let tmp = Self.folder.appendingPathComponent("\(stored.month).json.tmp")
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: tmp, to: dest)
    }

    private static func readMonth(_ key: String) -> StoredBucket? {
        let url = folder.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredBucket.self, from: data)
    }

    private static func monthFiles() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url -> String? in
            guard url.pathExtension == "json" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            return name.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil ? name : nil
        }.sorted()
    }

    private func pruneFolder() {
        let keys = Self.monthFiles()
        guard keys.count > Self.keepMonths else { return }
        for key in keys.prefix(keys.count - Self.keepMonths) where key != open.key {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(key).json"))
        }
    }

    private static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    #if DEBUG
    /// Where the month files live. The listening check points this at a
    /// temporary folder, so it never reads or writes a real library.
    nonisolated(unsafe) static var folderOverride: URL?
    /// Whether a sample reaches the disk and UserDefaults. The check turns this
    /// off: it is measuring the model, not the writer.
    nonisolated(unsafe) static var persistenceDisabled = false
    #endif

    private static var folder: URL {
        #if DEBUG
        if let folderOverride { return folderOverride }
        #endif
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("BitChord/listening", isDirectory: true)
    }

    nonisolated static func monthKey(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        return String(format: "%04d-%02d", cal.component(.year, from: date), cal.component(.month, from: date))
    }

    /// The calendar day a day key names, in this locale.
    nonisolated private static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }

    nonisolated private static func isoDay(_ date: Date) -> String {
        let cal = Calendar.current
        return String(
            format: "%04d-%02d-%02d",
            cal.component(.year, from: date),
            cal.component(.month, from: date),
            cal.component(.day, from: date)
        )
    }

    nonisolated static func primaryArtist(_ credit: String) -> String? {
        let first: String
        if let range = credit.range(of: listeningCreditPattern, options: [.regularExpression, .caseInsensitive]) {
            first = String(credit[..<range.lowerBound])
        } else {
            first = credit
        }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func albumKey(_ name: String, _ artist: String) -> String {
        name.lowercased() + "\u{1F}" + artist.lowercased()
    }
}

private let listeningCreditPattern = #"\s*,\s*|\s+&\s+|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+featuring\s+"#

struct Ranked: Identifiable {
    var name: String
    var ms: Double
    var browseId: String?
    var plays: Int = 0
    /// Secondary line — the album's artist, for an album row; unused for an
    /// artist or genre.
    var sub: String?
    /// Artwork. Collected and persisted all the way from the sample, and
    /// previously dropped when the summary was built, which is why the Replay
    /// artist and album charts rendered as empty circles.
    var art: String?
    var id: String { name }
}

struct ReplaySummary {
    var totalMs: Double
    var totalPlays: Int
    var songs: [ListeningStore.Track]
    var artists: [Ranked]
    var albums: [Ranked]
    var genres: [Ranked] = []
    var busiestDay: String?
    var busiestDayMs: Double
    var hourOfDay: [Double] = Array(repeating: 0, count: 24)
    var period: ListeningPeriod = .allTime
    var label: String = "All Time"
    var distinctSongs: Int = 0
    var distinctArtists: Int = 0
    var distinctAlbums: Int = 0
    var since: String?
    var minutes: Int { Int(totalMs / 60_000) }
    var isEmpty: Bool { songs.isEmpty }
}
