import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Home tab — upstream's "Play" tab: signed out it leads with the sign-in
/// banner over the anonymous home feed (FEmusic_home + new releases),
/// skeleton while loading, retry on error. Local music lives in Library.
struct HomeView: View {
    @Bindable var feed: FeedLoader
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(ToastCenter.self) private var toast
    /// An externally owned scroll position, when the caller survives the view:
    /// the Mac sidebar recreates this view on every row switch, and the feed
    /// is a singleton while the reader's place in it was not (upstream hoists
    /// `homeListState` outside its tab switch for the same reason).
    var scrollPosition: Binding<ScrollPosition>? = nil

    var body: some View {
        PageStack {
            content
                .navigationTitle("Listen Now")
                .toolbar {
                    #if os(iOS)
                    // Upstream FrostedTopBar's root-page leading BitChord logo.
                    TopBarLeadingItems()
                    ToolbarItem(placement: .topBarTrailing) { TopBarAccountButton() }
                    #endif
                }
                .refreshable { await loadFeed(force: true) }
                .task(id: auth.sessionEpoch) { await loadFeed(force: false) }
                .onAppear {
                    // Upstream's onHomeShown refetches only when a play has
                    // been registered since the feed was fetched
                    // (MainViewModel.kt:1478-1494): re-fetching otherwise
                    // would rearrange the page under whoever is reading it,
                    // and a NavigationStack root's onAppear fires on every
                    // pop back as well. "A play since" reads here as "the
                    // current track is not the one the feed loaded under".
                    if case .loaded = feed.phase,
                       feed.loadedDuringTrackId != controller.current?.id {
                        Task { await loadFeed(force: true) }
                    }
                }
                .onChange(of: feed.refreshError) { _, message in
                    // A refresh that failed over content leaves the content
                    // up, as upstream does — but silently. The toast is the
                    // difference between "nothing happened" and "this feed is
                    // from this morning".
                    if let message { toast.show(message) }
                }
        }
    }

    /// Every Home load goes through here so the loader knows what was playing
    /// when it finished — the staleness mark the onAppear check reads.
    private func loadFeed(force: Bool) async {
        await feed.load(force: force, epoch: auth.sessionEpoch)
        feed.noteLoaded(duringTrackId: controller.current?.id)
    }

    @ViewBuilder
    private var content: some View {
        switch feed.phase {
        case .loading:
            ScrollView { HomeFeedSkeleton() }
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchMusicNote),
                title: "Your feed couldn't load",
                subtitle: message,
                buttonTitle: "Retry"
            ) { Task { await feed.load() } }
        case .loaded(let shelves):
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !auth.signedIn {
                        SignInBanner { auth.loginPresented = true }
                    }
                    ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                        if index == 0, isRecentsShelf(shelf) {
                            RecentShelf(shelf: shelf)
                                .onAppear {
                                    if shelf.id == shelves.last?.id { Task { await feed.loadMore() } }
                                }
                        } else if index == 0 {
                            HeroShelf(shelf: shelf, preferTrack: true)
                                .onAppear {
                                    if shelf.id == shelves.last?.id { Task { await feed.loadMore() } }
                                }
                        } else {
                            ShelfCarousel(shelf: shelf, preferTrack: true)
                                .onAppear {
                                    if shelf.id == shelves.last?.id {
                                        Task { await feed.loadMore() }
                                    }
                                }
                        }
                    }
                    if feed.loadingMore {
                        ProgressView("Loading more")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else if let message = feed.paginationError {
                        HStack(spacing: 12) {
                            Label("More items couldn't load", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Retry") { Task { await feed.loadMore() } }
                        }
                        .font(.subheadline)
                        .padding(14)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .contain)
                        .accessibilityHint(message)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .modifier(ExternalScrollPosition(position: scrollPosition))
        }
    }

    /// Upstream's `RECENTS_TITLE` — the first shelf is a recents rail when the
    /// service titles it so, matched case-insensitively like upstream.
    private func isRecentsShelf(_ shelf: FeedShelf) -> Bool {
        let title = shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept the earlier Apple bridge title as well as upstream's canonical
        // "Recents" so the feed keeps the four-row treatment.
        return title == "recents" || title == "recently played"
    }
}

private enum RecentShelfLayout {
    static let columnSpacing: CGFloat = 12

    static func columnWidth(viewportWidth: CGFloat) -> CGFloat {
        min(viewportWidth * 0.88, 400)
    }

    static func placeholderCount(availableWidth: CGFloat, itemWidth: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int(ceil((availableWidth + spacing) / (itemWidth + spacing))))
    }
}

/// The upstream Home loading state reserves the Recents shelf and matches the
/// saved list/grid layout so content does not jump when the feed arrives.
private struct HomeFeedSkeleton: View {
    @State private var viewType = PlatformSettings.shared.getString(
        key: "home_recents_view_type", default: "LIST"
    )

    private var isList: Bool { viewType.uppercased() != "GRID" }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RecentsSkeletonBlock(height: 22, cornerRadius: 6).frame(width: 112)
                    Spacer(minLength: 8)
                    RecentsSkeletonBlock(height: 32, cornerRadius: 16).frame(width: 32)
                }
                if isList {
                    GeometryReader { geometry in
                        let columnWidth = RecentShelfLayout.columnWidth(viewportWidth: geometry.size.width + 48)
                        let count = RecentShelfLayout.placeholderCount(
                            availableWidth: geometry.size.width, itemWidth: columnWidth,
                            spacing: RecentShelfLayout.columnSpacing
                        )
                        HStack(alignment: .top, spacing: RecentShelfLayout.columnSpacing) {
                            ForEach(0..<count, id: \.self) { _ in
                                VStack(spacing: 0) {
                                    ForEach(0..<4, id: \.self) { index in
                                        HStack(spacing: 12) {
                                            RecentsSkeletonBlock(height: 48, cornerRadius: 7).frame(width: 48)
                                            VStack(alignment: .leading, spacing: 7) {
                                                RecentsSkeletonBlock(height: 14, cornerRadius: 4)
                                                    .frame(width: [150.0, 112.0, 134.0, 96.0][index])
                                                RecentsSkeletonBlock(height: 12, cornerRadius: 4)
                                                    .frame(width: [92.0, 122.0, 78.0, 106.0][index])
                                            }
                                            Spacer(minLength: 4)
                                            RecentsSkeletonBlock(height: 20, cornerRadius: 10).frame(width: 20)
                                        }
                                        .frame(height: 56)
                                    }
                                }
                                .frame(width: columnWidth, alignment: .leading)
                            }
                        }
                        .frame(width: geometry.size.width, alignment: .leading)
                        .clipped()
                    }
                    .frame(height: 4 * 56)
                } else {
                    GeometryReader { geometry in
                        let count = RecentShelfLayout.placeholderCount(
                            availableWidth: geometry.size.width, itemWidth: 160, spacing: 14
                        )
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(0..<count, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    RecentsSkeletonBlock(height: 160, cornerRadius: 10).frame(width: 160)
                                    RecentsSkeletonBlock(height: 14, cornerRadius: 4).frame(width: 118)
                                    RecentsSkeletonBlock(height: 12, cornerRadius: 4).frame(width: 82)
                                }
                            }
                        }
                        .frame(width: geometry.size.width, alignment: .leading)
                        .clipped()
                    }
                    .frame(height: 202)
                }
            }
            ForEach(0..<2, id: \.self) { shelf in
                SkeletonShelf(titleWidth: shelf == 0 ? 140 : 110, adaptive: true)
            }
        }
        // The loaded feed's spacing (28), so the shelves land where these were.
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

/// The Recents placeholder uses the same moving highlight sweep as upstream's
/// shimmer blocks, while respecting the listener's Reduce Motion setting.
private struct RecentsSkeletonBlock: View {
    let height: CGFloat
    var cornerRadius: CGFloat = 6
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.55)
                    // Scoped to the sweep's own offset, so a block resized by
                    // its layout snaps rather than bouncing with the shimmer.
                    .animation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        $0.offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.55)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(height: height)
        .onAppear { sweep = true }
        .accessibilityHidden(true)
    }
}

/// Upstream's `RecentShelf`: the first Home shelf when titled "Recents".
/// LIST mode is a horizontal rail of two columns × four track rows;
/// GRID mode is the ordinary card carousel. The choice persists in
/// `home_recents_view_type` like upstream's `homeRecentsViewType`.
struct RecentShelf: View {
    let shelf: FeedShelf
    @Environment(PlaybackController.self) private var controller

    /// LIST or GRID, persisted. Read off `PlatformSettings` rather than
    /// `@AppStorage` so the value is the same store the Android side reads.
    @State private var viewType: String = PlatformSettings.shared.getString(
        key: "home_recents_view_type", default: "LIST"
    )
    /// The grid row's own width, measured — the hero tile's height hangs off
    /// it, and a GeometryReader cannot supply that: its ideal height is ten
    /// points, and the heroes drew straight through the shelf below.
    @State private var gridWidth: CGFloat = 0

    private var isList: Bool { viewType.uppercased() != "GRID" }

    /// Upstream's hero width: 70% of the row, capped at 320.
    private var heroSide: CGFloat {
        guard gridWidth > 0 else { return 240 }
        return min(gridWidth * 0.70, 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recents").font(.title2.weight(.bold)).lineLimit(1)
                    if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    viewType = isList ? "GRID" : "LIST"
                    PlatformSettings.shared.putString(key: "home_recents_view_type", value: viewType)
                } label: {
                    Image(isList ? .bchGridView : .bchListView)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 19)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help(isList ? "Switch to grid view" : "Switch to list view")
                .accessibilityLabel(isList ? "Switch to grid view" : "Switch to list view")
            }
            if isList {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(shelf.items.chunked(4).enumerated()), id: \.offset) { _, column in
                                VStack(spacing: 0) {
                                    ForEach(column) { card in
                                        RecentTrackRow(card: card)
                                    }
                                }
                                // Upstream's trackColumnWidth is 88% of the
                                // viewport, capped at 400 points.
                                .frame(width: RecentShelfLayout.columnWidth(viewportWidth: geometry.size.width), alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: 4 * 56 + 4)
                .padding(.horizontal, -24)
            } else {
                // Upstream's Recents GRID mode is the hero treatment: the
                // same 0.92-ratio scrim-caption tiles as Home's first shelf.
                // The row's height is the tile's height, nothing extra — the
                // caption is inside the tile.
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.items) { card in
                            HeroCard(card: card, preferTrack: true, side: heroSide)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: heroSide * 0.92 + 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            }
        }
    }
}

/// One recent track: 48pt sleeve, title/artist, overflow menu. Matches
/// upstream's `RecentTrackRow` (artwork + two lines + more button), with the
/// now-playing accent the other shelf cards carry.
private struct RecentTrackRow: View {
    let card: ShelfCard
    @Environment(PlaybackController.self) private var controller

    /// Whether this row is the track loaded in the player right now.
    private var isCurrentTrack: Bool {
        guard let videoId = card.videoId, !videoId.isEmpty else { return false }
        return controller.current?.id == videoId
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let videoId = card.videoId, !videoId.isEmpty {
                    controller.playRadio(QueueEntry.youtube(
                        videoId: videoId, title: card.title, artist: card.subtitle ?? "",
                        thumbnailUrl: card.thumbnailUrl
                    ), context: "Recents")
                }
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(url: card.thumbnailUrl, data: nil, side: 48)
                        .clipShape(.rect(cornerRadius: 7, style: .continuous))
                        .modifier(NowPlayingCardAccent(
                            isCurrent: isCurrentTrack,
                            isPlaying: controller.isPlaying
                        ))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isCurrentTrack ? Theme.accent : .primary)
                            .lineLimit(1)
                        if let subtitle = card.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .shelfCardContextMenu(card)

            Menu { ShelfCardActionButtons(card: card) } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            #if os(macOS)
            // Without this the Mac draws a boxed pop-up button with a chevron.
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .tint(.gray)
            .accessibilityLabel("More actions for \(card.title)")
        }
        .padding(.vertical, 4)
    }
}

private extension Array {
    /// Splits into consecutive runs of `size`, like Kotlin's `chunked`.
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(Array(self[index..<end]))
            index = end
        }
        return out
    }
}
