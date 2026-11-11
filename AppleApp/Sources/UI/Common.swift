import SwiftUI
import BitChordShared
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Async artwork: YouTube thumbnail URLs, or embedded local artwork bytes.
/// Upstream sizes via the `w<n>-h<n>` hint (`Song.artworkAt` in shared).
struct ArtworkView: View {
    var url: String?
    var data: Data?
    var side: CGFloat?
    /// Fill the proposed area (edge-to-edge, cropped) instead of drawing a
    /// `side`-square: the mood tiles and any other caller whose artwork is a
    /// region rather than a thumbnail.
    var fill = false
    var fallbackInitials: String? = nil
    /// The id of a track in a remote file library, when the picture may be inside
    /// its file rather than beside it.
    ///
    /// Nil for everything else and no task runs, so the common case — a YouTube row —
    /// costs one optional and a comparison. Carried here rather than resolved by each
    /// caller because this is the one view every surface draws a track through: the
    /// library page, the queue, the mini player and the player itself, which is
    /// upstream's list of `rememberRemoteArtworkUrl` callers as well.
    var remoteId: String?
    @State private var embedded: Data?

    init(entry: QueueEntry?, side: CGFloat? = nil) {
        self.init(
            url: entry?.thumbnailUrl,
            data: entry?.artworkData,
            side: side,
            remoteId: entry.flatMap { EmbeddedArtwork.trackId(of: $0) }
        )
    }

    init(url: String?, data: Data?, side: CGFloat? = nil, remoteId: String? = nil, fill: Bool = false, fallbackInitials: String? = nil) {
        // Ask for the size the screen will actually draw at, on the screen's
        // actual scale. The old fixed `× 2` under-sampled every Retina row — a
        // 160pt card on a @3x display needs 480px and was being sent 320.
        let points = side ?? 300
        let scale = Double(PlatformScale.current)
        self.fill = fill
        self.fallbackInitials = fallbackInitials
        self.url = url.flatMap { SharedArtwork.sized($0, Int((points * scale).rounded())) }
        self.data = data
        self.side = side
        self.remoteId = remoteId
    }

    var body: some View {
        Group {
            if fill {
                artwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                artwork
                    .frame(width: side, height: side)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .background(.quaternary)
        .clipped()
        // No `.id()` here. Keying the subtree on the URL and byte count made
        // SwiftUI tear down and rebuild the whole image on every artwork change,
        // which showed up as a one-frame flicker on every track change. The
        // identity that matters is the row's, and the parent already has it.
        .accessibilityHidden(true)
        // Keyed on the track, so a row that scrolls round and comes back as a
        // different track re-resolves instead of showing the previous one's cover.
        .task(id: remoteId) {
            // Drop the previous track's cover first: a track without a remote id
            // (or one whose cover isn't extracted yet) would otherwise keep
            // drawing it, since `embedded` outranks the URL below.
            embedded = nil
            guard let remoteId else { return }
            let bytes = await EmbeddedArtwork.embeddedCoverData(id: remoteId)
            guard !Task.isCancelled else { return }
            embedded = bytes
        }
    }

    @ViewBuilder
    private var artwork: some View {
        // Bytes already in hand win: a downloaded track's own artwork, and a remote
        // track's extracted cover once it has arrived.
        if let bytes = data ?? embedded, let image = Self.image(from: bytes) {
            scaled(image)
        } else if let url, let cached = ArtworkCache.shared.get(url) {
            scaled(cached)
        } else if let url {
            RemoteArtwork(url: url, fallbackInitials: fallbackInitials)
        } else {
            placeholder
        }
    }

    /// One drawing of a decoded image, for both platforms.
    ///
    /// A function rather than an `#if` between `Image(…)` and `.resizable()`: the
    /// compiler cannot see a base for the chain across a conditional compilation
    /// boundary, and a view builder that returns `some View` from two branches is the
    /// shape it wants anyway.
    @ViewBuilder
    private func scaled(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #endif
    }

    private static func image(from data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)
        #else
        return NSImage(data: data)
        #endif
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            GeometryReader { proxy in
                Image(.bchMusicNote)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width * 0.4)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct RemoteArtwork: View {
    let url: String
    var fallbackInitials: String? = nil
    @State private var finished = false

    @ViewBuilder private var missingArtwork: some View {
        if let fallbackInitials {
            Text(fallbackInitials).font(.title2.weight(.semibold)).foregroundStyle(.secondary)
        } else if finished && LocalArtwork.isReference(url) {
            Image(.bchMusicNote).resizable().scaledToFit().padding(20).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
#if os(iOS)
    @State private var image: UIImage?
#else
    @State private var image: NSImage?
#endif

    var body: some View {
        Group {
#if os(iOS)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary.opacity(0.6))
                    .overlay { missingArtwork }
            }
#else
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary.opacity(0.6))
                    .overlay { missingArtwork }
            }
#endif
        }
        .task(id: url) {
            image = nil
            finished = false
            let result = await ArtworkCache.shared.load(url)
            guard !Task.isCancelled else { return }
            image = result
            finished = true
        }
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

/// The backing scale of the screen being drawn on, so artwork is requested at
/// the pixel size it will actually be drawn at.
///
/// macOS windows move between displays of different scale factors — a window
/// dragged from a Retina laptop panel to an external 1x monitor would otherwise
/// keep asking the CDN for 2× artwork it no longer needs, and would look soft on
/// the way back if the request had been cached at the smaller size.
enum PlatformScale {
    static var current: CGFloat {
        #if os(iOS)
        return UIScreen.main.scale
        #else
        return NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }
}

/// Memory + disk artwork cache — Apple stand-in for Coil's LRU.
///
/// ## Why the disk read is off the main thread
///
/// This used to be `@MainActor` with a synchronous `get(_:)` that did
/// `Data(contentsOf:)` plus an image decode inline, and it was called straight
/// from `ArtworkView.body` for every visible row. On a cold cache, scrolling a
/// 500-row library meant hundreds of file reads and image decodes on the main
/// thread — dropped frames, with the scroll gesture stuttering under it.
///
/// So the cache itself is no longer actor-isolated: the memory tier is an
/// `NSCache`, which is thread-safe by contract, and the disk tier is read on a
/// background executor. `get(_:)` still returns synchronously for the common
/// warm case (a memory hit) and returns nil for a cold one, which drops straight
/// through to [RemoteArtwork]'s async path — so the first paint of a cold row is
/// no slower than before, and every subsequent one is a memory hit.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, PlatformImage>()
    private let folder = DiskCache.cachesSubfolder("images")
    private static let diskLimit: Int64 = 128 * 1024 * 1024
    /// Serialises cold disk reads so a fast scroll does not queue hundreds of
    /// concurrent file reads for images that have already scrolled away.
    private let readQueue = DispatchQueue(
        label: "app.bitchord.BitChord.artwork-disk",
        qos: .userInitiated
    )

    init() {
        memory.totalCostLimit = 48 * 1024 * 1024
        memory.countLimit = 400
    }

    /// The warm path. A memory hit returns immediately; a miss returns nil and
    /// the caller falls back to its async load, which populates both tiers.
    private func cacheKey(_ url: String) -> String {
        if LocalArtwork.isReference(url) { return PageRequestCoordinator.digest(url) }
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: url)
        return PageRequestCoordinator.digest(url + headers.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\u{0}"))
    }
    func get(_ url: String) -> PlatformImage? {
        memory.object(forKey: cacheKey(url) as NSString)
    }

    /// Synchronous disk read, for the rare caller that genuinely needs the bytes
    /// before it can lay out. Off the main thread by construction.
    func getBlocking(_ url: String) -> PlatformImage? {
        if let hit = get(url) { return hit }
        var resolved: PlatformImage?
        readQueue.sync {
            resolved = readFromDisk(url)
        }
        return resolved
    }

    private static func decode(_ data: Data, url: String) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let requested: Int
        if let range = url.range(of: #"w\d+-h\d+"#, options: .regularExpression) {
            requested = min(2048, max(64, Int(url[range].dropFirst().split(separator: "-").first ?? "1200") ?? 1200))
        } else { requested = 1200 }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: requested,
            kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    private static func longestSide(_ image: PlatformImage) -> Int {
        #if os(iOS)
        return max(image.cgImage?.width ?? 0, image.cgImage?.height ?? 0)
        #else
        return Int(max(image.size.width, image.size.height))
        #endif
    }

    private func imageCost(_ image: PlatformImage) -> Int {
        #if os(iOS)
        return (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }

    private func readFromDisk(_ url: String) -> PlatformImage? {
        let file = diskURL(url)
        guard let data = try? Data(contentsOf: file), let image = Self.decode(data, url: url) else { return nil }
        // 1.0.4 could save a list thumbnail under a player-sized URL (issue 12).
        // A copy well under the size its URL asks for is passed over, so the
        // load goes back through the artwork store, which now only answers
        // with a cover at least that large (or the CDN's best).
        let requested = min(1200, OfflineArtworkStore.requestedPixels(url))
        if requested > 0, Self.longestSide(image) * 10 < requested * 9 { return nil }
        memory.setObject(image, forKey: cacheKey(url) as NSString, cost: imageCost(image))
        return image
    }

    func load(_ url: String) async -> PlatformImage? {
        if let hit = get(url) { return hit }
        let onDisk = await withCheckedContinuation { (cont: CheckedContinuation<PlatformImage?, Never>) in
            readQueue.async { [weak self] in cont.resume(returning: self?.readFromDisk(url)) }
        }
        if let onDisk { return onDisk }
        let headers = WebDavBridge.shared.playbackHeaders(fileUrl: url)
        let key = cacheKey(url)
        guard let data = await ArtworkRequests.shared.data(url: url, headers: headers), !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            readQueue.async { [weak self] in
                guard let self, key == self.cacheKey(url), let image = Self.decode(data, url: url) else {
                    continuation.resume(returning: nil); return
                }
                self.memory.setObject(image, forKey: key as NSString, cost: self.imageCost(image))
                try? data.write(to: self.diskURL(url), options: .atomic)
                // Trim per batch, rather than walking the folder after every tile.
                if Date().timeIntervalSince(self.lastTrim) > 60 {
                    self.lastTrim = Date()
                    DiskCache.trimFolder(self.folder, limitBytes: Self.diskLimit)
                }
                continuation.resume(returning: image)
            }
        }
    }
    private var lastTrim = Date.distantPast

    func clear() {
        memory.removeAllObjects()
        DiskCache.clearFolder(folder)
    }

    private func diskURL(_ url: String) -> URL {
        folder.appendingPathComponent(cacheKey(url))
    }
}

enum SharedArtwork {
    /// `String?.artworkAt(px)` from the shared module's model helpers.
    static func sized(_ url: String, _ px: Int) -> String? {
        if LocalArtwork.isReference(url) { return LocalArtwork.sizedReference(url, pixels: px) }
        guard let match = url.range(of: #"w\d+-h\d+"#, options: .regularExpression) else {
            return url
        }
        return url.replacingCharacters(in: match, with: "w\(px)-h\(px)")
    }
}

/// Upstream `Skeletons.kt`'s shimmer — the loading look on every feed.
struct SkeletonBlock: View {
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.Metrics.rowRadius
    @State private var phase: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(height: height)
            // A skeleton that still pulses is still motion. With Reduce Motion on
            // it is a static placeholder, which is what the setting is asking for.
            // The pulse is scoped to opacity alone: a value-scoped repeating
            // animation also caught any size change, so a block resized by
            // its layout bounced in and out forever.
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            ) { $0.opacity(reduceMotion ? 0.75 : (phase ? 0.5 : 0.9)) }
            .onAppear { phase = true }
            .accessibilityHidden(true)
    }
}

/// One loading song row: the 44pt art and the two text lines a `SongRow`
/// draws (upstream's `songRowSkeleton`), so a list keeps the shape it is
/// about to have instead of a spinner standing where content will be.
struct SkeletonSongRow: View {
    var showArt = true

    var body: some View {
        HStack(spacing: 12) {
            if showArt {
                SkeletonBlock(height: 44, cornerRadius: 8)
                    .frame(width: 44)
            }
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(height: 12)
                    .frame(maxWidth: 190, alignment: .leading)
                SkeletonBlock(height: 10)
                    .frame(maxWidth: 128, alignment: .leading)
            }
        }
        // SongRow's own padding around its 44pt art: 52pt a row.
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A loading list: enough placeholder rows to fill a screen, so the page is
/// already the shape it will be when the content lands. Upstream never shows
/// a bare full-screen spinner where list content is coming. One element for
/// VoiceOver — every block inside is hidden, so unmerged they would leave a
/// loading page saying nothing at all.
struct SkeletonRows: View {
    var count = 8
    var showArt = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<max(0, count), id: \.self) { _ in
                SkeletonSongRow(showArt: showArt)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// One loading shelf card, square like the artwork cards it stands in for.
struct SkeletonShelfCard: View {
    var side: CGFloat = Theme.Metrics.shelfCard
    var cornerRadius: CGFloat = 12

    var body: some View {
        SkeletonBlock(height: side, cornerRadius: cornerRadius)
            .frame(width: side)
    }
}

/// Music's centered empty state: glyph, bold title, subtitle, one bordered button.
///
/// The copy is `LocalizedStringKey`, not `String`: a call site passing a UI
/// phrase should get the translation from the catalog, and a plain `String`
/// parameter would render it verbatim.
struct EmptyStateView: View {
    var icon: Image
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    /// The subtitle when it is *not* catalog copy — a load error, a server's
    /// answer — set by the `StringProtocol` initializer below.
    var verbatimSubtitle: String?
    var buttonTitle: LocalizedStringKey?
    var action: (() -> Void)?

    init(
        icon: Image,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        buttonTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.verbatimSubtitle = nil
        self.buttonTitle = buttonTitle
        self.action = action
    }

    /// For text that is data rather than copy: a `404`, a timeout, a server's
    /// own message.
    ///
    /// It is drawn with `Text(verbatim:)` because a `LocalizedStringKey` built
    /// from a runtime string is still parsed as Markdown — underscores would turn
    /// italic, asterisks bold, and a URL in an error message into a link that
    /// points somewhere the message never meant.
    ///
    /// `@_disfavoredOverload` is the same attribute SwiftUI puts on
    /// `Text.init(_:)`'s `StringProtocol` form: without it a string *literal*
    /// would resolve to this initializer (a literal's default type is `String`)
    /// and every empty state would stop being localized. With it, literals keep
    /// the `LocalizedStringKey` initializer above and only real `String` values
    /// land here.
    @_disfavoredOverload
    init<S: StringProtocol>(
        icon: Image,
        title: LocalizedStringKey,
        subtitle: S,
        buttonTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = ""
        self.verbatimSubtitle = String(subtitle)
        self.buttonTitle = buttonTitle
        self.action = action
    }

    /// The subtitle resolved to the text the view draws: catalog copy, or the
    /// runtime text as-is.
    private var subtitleLabel: Text {
        verbatimSubtitle.map { Text(verbatim: $0) } ?? Text(subtitle)
    }

    var body: some View {
        VStack(spacing: 12) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 42)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.bold))
            subtitleLabel
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Three bars that move while a track plays: the indicator Music puts beside the
/// row that is playing, so a list says which row it is rather than only colouring
/// its title. Static under Reduce Motion.
struct PlayingBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = .accentColor
    @State private var phase = false

    private static let shapes: [[CGFloat]] = [[4, 10, 7], [10, 5, 9], [7, 9, 4]]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: height(index))
            }
        }
        .frame(width: 14, height: 11, alignment: .bottom)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
            value: phase
        )
        .onAppear { phase = true }
        .accessibilityLabel("Playing")
    }

    private func height(_ index: Int) -> CGFloat {
        guard !reduceMotion else { return Self.shapes[0][index] }
        return Self.shapes[phase ? 1 : 0][index]
    }
}

/// A credit line whose artist names each open their own artist page.
///
/// The track carries only its *first* artist's browse id; that name opens the
/// page directly and every other name is looked up by exact name (see
/// `AppModel.openArtist`), falling back to a search when nothing matches.
struct ArtistCreditText: View {
    let credit: String
    /// The first credited artist's browse id, when the track has one.
    var artistId: String? = nil
    var font: Font
    var color: Color
    /// A trailing, unlinked part of the line — the album, in the deck's
    /// "artist — album" credit.
    var suffix: String? = nil
    /// Crawl when too long (upstream's `ArtistCreditsMarquee`) rather than
    /// end in an ellipsis; nil keeps a plain one-line truncation.
    var marquee: (enabled: Bool, startDelay: Double)? = nil
    @Environment(AppModel.self) private var appModel

    private var names: [String] {
        credit.split(whereSeparator: { $0 == "," || $0 == "&" || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        if let marquee {
            Marquee(enabled: marquee.enabled, startDelay: marquee.startDelay) { line }
        } else {
            line.lineLimit(1)
        }
    }

    private var line: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(color)
            // Names are drawn in the line's own colour, as upstream draws them:
            // a tappable credit, not a row of accent-blue links.
            .tint(color)
            .environment(\.openURL, OpenURLAction { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                guard url.scheme == "bitchord", url.host == "artist",
                      let name = items?.first(where: { $0.name == "name" })?.value else {
                    return .systemAction
                }
                let index = items?.first(where: { $0.name == "index" })?.value.flatMap(Int.init) ?? 0
                appModel.openArtist(named: name, knownId: index == 0 ? artistId : nil)
                return .handled
            })
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let parts = names.isEmpty ? [credit] : names
        for (index, name) in parts.enumerated() {
            var piece = AttributedString(name)
            var components = URLComponents()
            components.scheme = "bitchord"
            components.host = "artist"
            components.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "index", value: String(index))
            ]
            piece.link = components.url
            out += piece
            if index < parts.count - 1 { out += AttributedString(", ") }
        }
        if let suffix, !suffix.isEmpty {
            out += AttributedString(suffix)
        }
        return out
    }
}

/// The one selected row in a window.
///
/// Selection cannot live in each row: a `@State` per row keeps every row that
/// has ever been clicked highlighted, so three clicks leave three rows selected.
/// A Mac list has one selection — a click replaces it — and that is a single id
/// the window owns and every row reads.
@Observable
final class RowSelection {
    var id: String?

    /// The rows of the page in view, in the order they are drawn.
    ///
    /// Registered by the page, because a row knows what it is but not who its
    /// neighbours are, and the arrow keys are a question about neighbours. Pages
    /// that never register anything still support clicking, Tab and Return,
    /// without arrow navigation.
    private(set) var order: [String] = []

    func select(_ id: String) {
        self.id = id
    }

    /// Hand the page's rows over.
    func setOrder(_ ids: [String]) {
        guard order != ids else { return }
        order = ids
        // A selection that is not on this page is not a selection: it would draw
        // the highlight on a row the reader has left.
        if let id, !ids.contains(id) { self.id = ids.first }
    }

    /// Forget a page's rows, but only if they are still the registered ones: the
    /// next page's `onAppear` can run before this page's `onDisappear`, and a
    /// blanket clear would empty the page the reader has just arrived at.
    func clearOrder(ifMatching ids: [String]) {
        guard order == ids else { return }
        order = []
    }

    /// Walk the page's rows. Reports whether the selection moved, so a key that
    /// has nowhere to go is left for whatever else would have handled it.
    @discardableResult
    func move(by offset: Int) -> Bool {
        guard !order.isEmpty else { return false }
        let target: String
        if let id, let index = order.firstIndex(of: id) {
            target = order[min(max(index + offset, 0), order.count - 1)]
        } else {
            target = offset > 0 ? order[0] : order[order.count - 1]
        }
        guard target != id else { return false }
        select(target)
        return true
    }
}

/// The page's keyboard focus, keyed by row id.
///
/// A key press is delivered to the *focused* row, so arrow navigation needs the
/// focus to move with the selection: a selection that moved on its own would walk
/// once and then stop. The page owns the focus (it knows its rows' order); the
/// row only joins it.
private struct RowFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<String?>.Binding? = nil
}

extension EnvironmentValues {
    var rowFocus: FocusState<String?>.Binding? {
        get { self[RowFocusKey.self] }
        set { self[RowFocusKey.self] = newValue }
    }
}

private struct RowSelectionKey: EnvironmentKey {
    static let defaultValue: RowSelection? = nil
}

extension EnvironmentValues {
    var rowSelection: RowSelection? {
        get { self[RowSelectionKey.self] }
        set { self[RowSelectionKey.self] = newValue }
    }
}

/// A queue row: artwork, title/artist, duration; hover highlight, context
/// menu (macOS nuance from UI spec §5). Rows always show a sleeve — album
/// tracks that omit per-song art inherit the page cover at the call site.
struct SongRow: View {
    let entry: QueueEntry
    var isCurrent: Bool = false
    var play: () -> Void
    var playNext: (() -> Void)?
    var addToQueue: (() -> Void)?
    var playlistBrowseId: String? = nil
    var playlistOwned: Bool = false

    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hovering = false
    @Environment(\.rowSelection) private var rowSelection

    /// How many lines a track's text may take.
    ///
    /// One at ordinary sizes, because this is the most-repeated row in the app and
    /// a list of wrapping rows is a list nobody can scan. Two once the reader has
    /// asked for larger text: a row that truncates harder as somebody needs it more
    /// is the opposite of what the setting is for, and this is where that shows
    /// first — a long title is exactly what stops being readable.
    private var titleLines: Int? { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

    private var active: Bool { isCurrent || controller.current?.id == entry.id }
    /// Whether this is the window's selected row.
    private var isSelected: Bool {
        #if os(macOS)
        rowSelection?.id == entry.id
        #else
        false
        #endif
    }
    private var buffering: Bool { controller.current?.id == entry.id && controller.isBuffering }

    /// Rows observe only the presence index, without scanning or validating assets.
    private var isDownloaded: Bool {
        !entry.isLocal && DownloadStore.shared.isDownloaded(entry)
    }

    var body: some View {
        Group {
            #if os(macOS)
            rowContent
                .modifier(MacRowInteraction(
                    id: entry.id,
                    play: play,
                    selection: rowSelection
                ))
            #else
            // A phone row is the play button itself: there is no pointer to
            // select with, and a double click would mean starting it twice.
            Button(action: play) {
                rowContent
            }
            .buttonStyle(.plain)
            #endif
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.rowRadius, style: .continuous)
                .fill(rowFill)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(active || isSelected ? [.isButton, .isSelected] : .isButton)
        #if os(macOS)
        // The element ignores its children, so its actions belong on the element
        // rather than inside the row: VoiceOver's press and "Play" both start it,
        // as they did when the row was a Button.
        .accessibilityAction { play() }
        .accessibilityAction(named: "Play") { play() }
        #endif
        .songContextMenu(entry, playlistBrowseId: playlistBrowseId, playlistOwned: playlistOwned)
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            let playNext = PlatformSettings.shared.getBoolean(key: "swipe_to_play_next", default: false)
            if playNext {
                Button { (self.playNext ?? { controller.playNext(entry) })() } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.orange)
            } else {
                Button { (self.addToQueue ?? { controller.addToQueue(entry) })() } label: {
                    Label("Queue", systemImage: "text.badge.plus")
                }
                .tint(.blue)
            }
            if auth.signedIn, let vid = entry.videoId {
                Button {
                    // Through the controller, so this row's heart reports a
                    // refusal the same way the player's does. It used to call
                    // `rate` directly and discard the answer.
                    controller.toggleLike(videoId: vid)
                } label: {
                    Label(LibraryActions.cachedLike(vid) == "LIKE" ? "Unlike" : "Like", systemImage: LibraryActions.cachedLike(vid) == "LIKE" ? "heart.fill" : "heart")
                }
                .tint(.pink)
            }
            if !entry.isLocal {
                Button {
                    switch DownloadStore.shared.download(entry) {
                    case .started:
                        toast.show("Downloading \(entry.title)")
                    case .blockedByWifiOnly:
                        toast.show("Downloads are limited to Wi-Fi. Turn that off in Settings to use mobile data.", kind: .failure)
                    case .alreadyExists:
                        toast.show("\(entry.title) is already downloading or downloaded", kind: .info)
                    case .ignoredLocalTrack:
                        break
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.indigo)
            }
        }
        #endif
    }

    /// The lane itself, shared by both platforms' interaction wrappers.
    private var rowContent: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(entry: entry, side: 44)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                if buffering {
                    ProgressView().controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.body.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.accentColor : .primary)
                        .lineLimit(titleLines)
                    if active { PlayingBars() }
                }
                if !entry.artist.isEmpty {
                    Text(entry.artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(titleLines)
                }
            }
            Spacer(minLength: 8)
            if let activity = DownloadStore.shared.activity(for: entry), activity.phase != .saved {
                DownloadProgressIndicator(activity: activity)
            } else if isDownloaded {
                // Upstream's downloadedTint: the row says the song is already
                // on the device, so a Download menu row is not a mystery.
                Image(systemName: "arrow.down.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            }
            if let text = entry.durationText, !text.isEmpty {
                Text(text)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(.bchChevronRight)
                .resizable()
                .scaledToFit()
                .frame(width: 12)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .decorative()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(.rect)
    }

    private var rowFill: Color {
        #if os(macOS)
        // A selected row outranks the playing and hover tints, including when
        // keyboard navigation selects a row without starting playback.
        if isSelected { return Color.accentColor.opacity(0.16) }
        #endif
        if active { return Color.primary.opacity(0.08) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    /// One sentence for the whole row, in the order a person would say it.
    private var accessibilityLabel: String {
        var parts = [entry.title]
        if !entry.artist.isEmpty { parts.append(entry.artist) }
        if let duration = entry.durationText, !duration.isEmpty { parts.append(duration) }
        if buffering { parts.append("Buffering") }
        if let activity = DownloadStore.shared.activity(for: entry) { parts.append(activity.label) }
        return parts.joined(separator: ", ")
    }
}

/// Repeat glyph with a centred "1" when only the current track is looping —
/// the same differentiator Music uses on `repeat.1`.
struct RepeatGlyph: View {
    var mode: PlaybackController.RepeatMode
    var size: CGFloat = 15

    var body: some View {
        ZStack {
            Image(.bchRepeat)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
            if mode == .one {
                Text("1")
                    .scaledFont(size: max(7, size * 0.42), weight: .bold, design: .rounded)
                    .offset(y: size * 0.02)
            }
        }
        .accessibilityLabel(mode == .one ? "Repeat one" : mode == .all ? "Repeat all" : "Repeat off")
    }
}

/// Upstream `ThinSlider.kt` — hairline capsule, Automix window marker, mix sheen.
///
/// Hand-drawn rather than a `Slider` because a native one cannot show the Automix
/// transition window or the mix sheen behind the playhead. That is a fair trade
/// only if the control then behaves like a slider to assistive technology, which
/// it did not: it published an `accessibilityValue` with no label and no
/// adjustable action, so a VoiceOver user could not seek at all.
struct ThinSlider: View {
    let value: Double
    let maximum: Double
    var label: String = "Playback position"
    var mixing: Bool = false
    var transitionWindow: ClosedRange<Double>? = nil
    var onEditingChanged: (Double) -> Void
    var onDraggingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var dragValue: Double?

    private var current: Double { dragging ? (dragValue ?? value) : value }

    private var fraction: Double {
        guard maximum > 0 else { return 0 }
        return min(max(current / maximum, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let height: CGFloat = dragging ? 12 : 7
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.26))
                if !dragging, let window = transitionWindow, window.upperBound > window.lowerBound {
                    let from = geo.size.width * window.lowerBound
                    let to = geo.size.width * window.upperBound
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: max(0, to - from))
                        .offset(x: from)
                }
                if fraction > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .overlay {
                            if mixing && !dragging { MixSheenBar().opacity(0.35) }
                        }
                        .clipShape(Capsule())
                        .frame(width: max(height, geo.size.width * fraction))
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { onDraggingChanged(true) }
                        dragging = true
                        let f = min(max(g.location.x / geo.size.width, 0), 1)
                        dragValue = f * maximum
                    }
                    .onEnded { _ in
                        if let v = dragValue { onEditingChanged(v) }
                        dragging = false
                        dragValue = nil
                        onDraggingChanged(false)
                    }
            )
            .animation(Motion.once(reduceMotion, duration: 0.28, curve: .spring(response: 0.28, dampingFraction: 0.72)), value: dragging)
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(NowPlayingView.timestamp(current))
        // One second per increment, five seconds per decrement, matching what
        // Music does and what a seek bar is expected to feel like when driven from
        // a screen reader rather than a drag.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onEditingChanged(min(maximum, current + 1))
            case .decrement: onEditingChanged(max(0, current - 5))
            @unknown default: break
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

private struct MixSheenBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The sheen is a 30fps animated band crossing the playhead to show an
        // Automix transition in progress. With Reduce Motion on it would be the
        // single most active thing on screen, so it is replaced by a static tint
        // that still reads as "something is happening here".
        if reduceMotion {
            Capsule().fill(Color.white.opacity(0.22))
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let period = 0.5
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: period) / period
                    let band = size.width * 0.7
                    let centre = -band + (size.width + band * 2) * phase
                    let gradient = Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.95), location: 0.5),
                        .init(color: .clear, location: 1),
                    ])
                    context.fill(
                        Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2),
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: centre - band / 2, y: 0),
                            endPoint: CGPoint(x: centre + band / 2, y: 0)
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Transport haptics — upstream `Haptics.kt`, respecting system settings.
enum PlaylistPinning {
    static let maxPins = 5

    static func pinnedIds() -> [String] {
        PlatformSettings.shared.getString(key: "pinned_playlists", default: "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Returns false when a sixth pin would be added — caller should toast.
    @discardableResult
    static func toggle(browseId: String) -> Bool {
        let before = pinnedIds()
        if !before.contains(browseId), before.count >= maxPins { return false }
        return AppSettings.shared.togglePinnedPlaylist(browseId: browseId) || before.contains(browseId)
    }
}

@MainActor
enum PlayerParity {
    static func mixInProgress(_ controller: PlaybackController) -> Bool {
        controller.smartMixInProgress
    }

    static func transitionWindow(_ controller: PlaybackController) -> ClosedRange<Double>? {
        guard let w = controller.smartTransitionWindow, w.end > w.start else { return nil }
        return w.start...w.end
    }

    static func sleepStatus(_ controller: PlaybackController) -> String? {
        controller.sleepTimerStatus
    }

    static func debugLog(_ controller: PlaybackController) -> String {
        let dump = controller.debugLogText
        return dump.isEmpty ? "No debug lines yet." : dump
    }

    static func lyricsSourceLabel(_ controller: PlaybackController) -> String? {
        guard let label = controller.lyricsSourceLabel, !label.isEmpty else { return nil }
        return label
    }

    static func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum LyricsSourceNames {
    /// The order the shared module asks sources in, with the current enabled set.
    ///
    /// Read from `AppSettings` rather than listed here. The host used to carry
    /// its own list of source names, and every source added since went into the
    /// enum and not into it — so this default was quietly a different set from
    /// the real one, and the *only* thing it was used for was the first read,
    /// before the shared module had been asked.
    static var defaultOrder: [String] {
        LyricsSourceCatalog.names()
    }

    static var defaultEnabled: String {
        defaultOrder.filter { $0 != "SIMP_MUSIC" }.joined(separator: ",")
    }

    static func canonical(_ id: String) -> String {
        switch id.trimmingCharacters(in: .whitespaces) {
        case "PLUS": "LYRICS_PLUS"
        case "BETTER": "BETTER_LYRICS"
        case "SIMP": "SIMP_MUSIC"
        default: id
        }
    }

    static func normalizeList(_ raw: String) -> String {
        raw.split(separator: ",").map { canonical(String($0)) }.filter { !$0.isEmpty }.joined(separator: ",")
    }

    /// The display name, from the shared module.
    ///
    /// A table here was a third copy of the same fact, and the one place it
    /// mattered most — what a source is called in the list — was the copy least
    /// likely to be updated.
    static func label(_ id: String) -> String {
        LyricsSourceCatalog.label(for: canonical(id)) ?? canonical(id)
    }
}

/// The shared lyrics catalogue, decoded once.
enum LyricsSourceCatalog {
    private struct Entry: Decodable {
        let name: String
        let label: String
    }

    private static let entries: [Entry] = {
        guard let data = AppSettings.shared.lyricsSourceCatalogJson().data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }()

    static func names() -> [String] { entries.map(\.name) }

    static func label(for name: String) -> String? {
        entries.first { $0.name == name }?.label
    }
}


/// The Mac's row interaction: play on one click by default, or select on one
/// click and play on two when Single-Click to Play is off. Tab, Return and arrow
/// navigation work in either mode; Space plays the row when the window's
/// play/pause handler has not already handled it.
///
/// Its own modifier rather than nine links in the row's chain: the chain was long
/// enough that the type checker gave up on it, and the row's body reads better
/// when the Mac's interaction is named.
#if os(macOS)
private struct MacRowInteraction: ViewModifier {
    let id: String
    let play: () -> Void
    let selection: RowSelection?
    @AppStorage("mac_single_click_play") private var singleClickToPlay = true

    func body(content: Content) -> some View {
        clickTarget(content)
            .allowsWindowActivationEvents(true)
            // Keep keyboard focus in either click mode. Return plays the row;
            // Space is a fallback when the window has no transport handler.
            // VoiceOver's press is supplied by SongRow's default action.
            .focusable()
            .focusedRow(id)
            .onKeyPress(.return, phases: .down, action: activate)
            .onKeyPress(.space, phases: .down, action: activate)
            // Up and down walk the page's rows. Only the bare keys: ⌘↑ and ⌘↓ are
            // the volume commands and must reach them. `move` answers whether it
            // went anywhere, so at the ends of a list the key is left alone and can
            // still scroll the page underneath.
            .onKeyPress(.downArrow, phases: .down) { press in
                MacRowInteraction.walk(press, by: 1, selection: selection)
            }
            .onKeyPress(.upArrow, phases: .down) { press in
                MacRowInteraction.walk(press, by: -1, selection: selection)
            }
    }

    @ViewBuilder
    private func clickTarget(_ content: Content) -> some View {
        if singleClickToPlay {
            // Do not install a competing double-tap recognizer in this mode:
            // the first click should start playback without a double-click wait.
            content.contentShape(.rect)
                .onTapGesture {
                    selection?.select(id)
                    play()
                }
        } else {
            content.contentShape(.rect)
                .onTapGesture(count: 2) {
                    selection?.select(id)
                    play()
                }
                .onTapGesture { selection?.select(id) }
        }
    }

    private func activate(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !MacKeyboardInput.isEditingText else { return .ignored }
        play()
        return .handled
    }

    private static func walk(_ press: KeyPress, by offset: Int, selection: RowSelection?) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !MacKeyboardInput.isEditingText else { return .ignored }
        let moved: Bool = selection?.move(by: offset) ?? false
        return moved ? .handled : .ignored
    }
}
#endif

/// Which lyric line the playhead is in.
///
/// One implementation for the player's strip and the Mac's menu bar, because both
/// show the same line on the same adjusted clock: the offset shifts both, and two
/// copies of "which line is current" would be two answers to one question.
enum CurrentLyricLine {
    static func line(in lines: [LyricLineDto], at position: Double, offsetMs: Int32) -> String? {
        guard !lines.isEmpty else { return nil }
        // A sheet with no timings on it (plain text lyrics every parser hands over
        // the same way) has no line *at* the playhead: the last one would be
        // "current" for the whole track, in the strip and the menu bar both.
        guard lines.contains(where: { $0.timeMs > 0 }) else { return nil }
        let ms = max(0, Int64(position * 1000) - Int64(offsetMs))
        guard let index = lines.lastIndex(where: { $0.timeMs <= ms }) else { return nil }
        return lines[index].text
    }
}

/// The page half of keyboard navigation: it hands its rows over and lets the
/// keyboard focus follow the selection.
///
/// One line per page, because the page is the only thing that knows the order of
/// its own rows. Pages that do not ask for it keep today's behaviour, and a page
/// whose rows are not `SongRow`s (cards, shelves) is unchanged too.
extension View {
    func rowKeyboardNavigation(ids: [String]) -> some View {
        modifier(RowKeyboardNavigation(ids: ids))
    }
}

private struct RowKeyboardNavigation: ViewModifier {
    let ids: [String]
    @Environment(\.rowSelection) private var rowSelection
    @FocusState private var focusedRow: String?

    func body(content: Content) -> some View {
        content
            .environment(\.rowFocus, $focusedRow)
            .onAppear { rowSelection?.setOrder(ids) }
            .onChange(of: ids) { _, new in rowSelection?.setOrder(new) }
            .onDisappear { rowSelection?.clearOrder(ifMatching: ids) }
            .onChange(of: rowSelection?.id) { _, new in
                guard let new else { return }
                focusedRow = new
            }
    }
}

/// The row half: join the page's focus when the page has one.
private struct FocusedRowModifier: ViewModifier {
    let id: String
    @Environment(\.rowFocus) private var rowFocus

    func body(content: Content) -> some View {
        if let rowFocus {
            content.focused(rowFocus, equals: id)
        } else {
            content
        }
    }
}

extension View {
    fileprivate func focusedRow(_ id: String) -> some View {
        modifier(FocusedRowModifier(id: id))
    }
}
