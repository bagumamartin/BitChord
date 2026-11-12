import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import AVFAudio
#else
import AppKit
#endif

/// Queue column. The current song stays in the compact player header when
/// there is no neighbouring player column (portrait); wide layouts already have
/// that information beside the queue, so they omit the duplicate header.
struct UpNextPane: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AuthController.self) private var auth
    @Environment(AppModel.self) private var appModel

    var showsCurrentTrackHeader = true
    var onOpenLyrics: () -> Void = {}
    @State private var hasScrolledOnce = false
    @State private var queueSearch = ""
    @State private var historyExpanded = false
    @State private var manualExpanded = true
    @State private var autoplayExpanded = true
    @AppStorage("show_queue_history") private var showQueueHistory = false

    /// The queue list, one layout on every platform: "Queue" with Clear, a
    /// "Now playing" section for the current track, "Up next" with drag
    /// handles left and remove buttons right, the AutoPlay section, and a
    /// Lyrics link at the foot. iPad and mac used to render a separate
    /// "Continue Playing" list (no sections, swipe-only delete); the two
    /// layouts disagreed about what a queue is, so there is one now.
    @ViewBuilder
    var body: some View {
        queueList
    }

    private var queueList: some View {
        let _ = LikeStore.shared.epoch
        return VStack(alignment: .leading, spacing: 12) {
            // The big current-track header (artwork, like, menu) only where
            // the artwork column is absent. iPad landscape and mac show all
            // of that on the left already; repeating it here doubles the
            // song, the like and the menu.
            if showsCurrentTrackHeader {
                queueHeader
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Queue")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: openMusicSearch) {
                    Label("Add Music", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                if !manualUpcoming.isEmpty || !autoplayUpcoming.isEmpty {
                    Button("Clear") { controller.clearUpcoming() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 24)
            .id("queueTop")

            if !allQueueRows.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.55))
                    TextField("Find in queue", text: $queueSearch)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                    if !queueSearch.isEmpty {
                        Button { queueSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.65))
                            .accessibilityLabel("Clear queue search")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
            }

            if controller.current == nil && manualUpcoming.isEmpty && autoplayUpcoming.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nothing playing.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                    Button {
                        openMusicSearch()
                    } label: {
                        Label("Find Music", systemImage: "magnifyingglass")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.18))
                }
                .padding(.top, 8)
                .padding(.horizontal, 24)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        if !queueSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           filteredHistoryRows.isEmpty, filteredManualUpcoming.isEmpty, filteredAutoplayUpcoming.isEmpty {
                            Text("No queue matches")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.55))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        if !filteredHistoryRows.isEmpty {
                            sectionHeader("Previously Played", count: filteredHistoryRows.count, expanded: $historyExpanded)
                            if historyExpanded {
                                ForEach(filteredHistoryRows) { item in historyQueueRow(item) }
                            }
                        }
                        if controller.current != nil {
                            Text("Now playing")
                                .font(.headline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.top, 12)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 12, leading: 24, bottom: 6, trailing: 24))
                            currentQueueRow
                        }
                        if !filteredManualUpcoming.isEmpty {
                            sectionHeader("Up next", count: filteredManualUpcoming.count, expanded: $manualExpanded, topPadding: 16)
                            if manualExpanded {
                                ForEach(Array(filteredManualUpcoming.enumerated()), id: \.element.id) { localIndex, item in
                                    queueListRow(item, section: 0, index: manualUpcoming.firstIndex(where: { $0.index == item.index }) ?? localIndex, rows: manualUpcoming)
                                }
                                .onMove { source, dest in move(source, dest, rows: filteredManualUpcoming) }
                                .onDelete { offsets in remove(offsets, rows: filteredManualUpcoming) }
                            }
                        }
                        if controller.autoplayEnabled || !autoplayUpcoming.isEmpty {
                            Button { autoplayExpanded.toggle() } label: {
                            HStack(spacing: 8) {
                                Image(.bchInfinity)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .foregroundStyle(.white.opacity(0.75))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("AutoPlay · \(filteredAutoplayUpcoming.count)")
                                        .font(.headline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text(autoplayUpcoming.isEmpty
                                         ? "Similar music will keep playing"
                                         : "Similar music, selected to play next")
                                        .font(.callout)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer()
                                Image(systemName: autoplayExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("AutoPlay, \(filteredAutoplayUpcoming.count) tracks")
                            .padding(.vertical, 14)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
                            if autoplayExpanded && !filteredAutoplayUpcoming.isEmpty {
                                ForEach(Array(filteredAutoplayUpcoming.enumerated()), id: \.element.id) { localIndex, item in
                                    queueListRow(item, section: 1, index: autoplayUpcoming.firstIndex(where: { $0.index == item.index }) ?? localIndex, rows: autoplayUpcoming)
                                }
                                .onMove { source, dest in move(source, dest, rows: filteredAutoplayUpcoming) }
                                .onDelete { offsets in remove(offsets, rows: filteredAutoplayUpcoming) }
                            }
                        }
                        Button {
                            Haptics.play(.expand)
                            onOpenLyrics()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .font(.body.weight(.medium))
                                Text("Lyrics")
                                    .font(.headline.weight(.medium))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.04),
                                .init(color: .black, location: 0.96),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .animation(.easeOut(duration: 0.2), value: queueSignature)
                    .onChange(of: controller.playingIndex) { _, _ in
                        if hasScrolledOnce {
                            withAnimation {
                                proxy.scrollTo(showQueueHistory ? "nowPlaying" : "queueTop", anchor: .top)
                            }
                        } else {
                            proxy.scrollTo(showQueueHistory ? "nowPlaying" : "queueTop", anchor: .top)
                            hasScrolledOnce = true
                        }
                    }
                    .onAppear {
                        guard showQueueHistory else { return }
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("nowPlaying", anchor: .top)
                            hasScrolledOnce = true
                        }
                    }
                    .onChange(of: showQueueHistory) { _, enabled in
                        guard enabled else { return }
                        withAnimation { proxy.scrollTo("nowPlaying", anchor: .top) }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func openMusicSearch() {
        appModel.nowPlayingPresented = false
        appModel.requestedTab = .search
        appModel.focusSearch = true
        appModel.searchFocusTrigger &+= 1
    }

    private func sectionHeader(_ title: String, count: Int, expanded: Binding<Bool>, topPadding: CGFloat = 12) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, topPadding)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: topPadding, leading: 24, bottom: 6, trailing: 24))
        .accessibilityLabel("\(title), \(count) tracks, \(expanded.wrappedValue ? "expanded" : "collapsed")")
    }

    private var currentQueueRow: some View {
        Button {
            let at = controller.playingIndex
            if controller.queue.indices.contains(at) {
                controller.playQueueItem(at: at)
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(entry: controller.current, side: 40)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.current?.title ?? "")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    ArtistCreditText(
                        credit: controller.current?.artist ?? "",
                        artistId: controller.current?.artistId,
                        font: .caption,
                        color: .white.opacity(0.65)
                    )
                }
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Now playing")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .id("nowPlaying")
    }

    private var historyRows: [QueueRow] {
        guard showQueueHistory, controller.playingIndex > 0 else { return [] }
        return (0..<min(controller.playingIndex, controller.queue.count)).map { index in
            QueueRow(index: index, entry: controller.queue[index])
        }
    }

    private var allQueueRows: [QueueRow] { historyRows + manualUpcoming + autoplayUpcoming }

    private var filteredHistoryRows: [QueueRow] { filtered(historyRows) }
    private var filteredManualUpcoming: [QueueRow] { filtered(manualUpcoming) }
    private var filteredAutoplayUpcoming: [QueueRow] { filtered(autoplayUpcoming) }

    private func filtered(_ rows: [QueueRow]) -> [QueueRow] {
        let query = queueSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { QueueSearchPolicy.matches(title: $0.entry.title, artist: $0.entry.artist, query: query) }
    }

    private func historyQueueRow(_ item: QueueRow) -> some View {
        Button {
            controller.playQueueItem(at: item.index)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(entry: item.entry, side: 44)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.entry.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.entry.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(item.entry.title), previously played")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 20))
    }

    private func queueListRow(_ item: QueueRow, section: Int, index: Int, rows: [QueueRow]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 20, height: 44)
                .contentShape(.rect)
                .onDrag { NSItemProvider(object: "\(section):\(index)" as NSString) }
            Button {
                controller.playQueueItem(at: item.index)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(entry: item.entry, side: 44)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.entry.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(item.entry.artist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button {
                controller.removeFromQueue(at: item.index)
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.entry.title) from queue")
            if let videoId = controller.youtubeVideoID(for: item.entry) {
                Button {
                    controller.toggleLike(videoId: videoId)
                } label: {
                    Image(systemName: LibraryActions.cachedLike(videoId) == "LIKE" ? "heart.fill" : "heart")
                        .font(.body.weight(.medium))
                        .foregroundStyle(LibraryActions.cachedLike(videoId) == "LIKE" ? Color.accentColor : .white.opacity(0.55))
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LibraryActions.cachedLike(videoId) == "LIKE" ? "Remove \(item.entry.title) from Liked Music" : "Like \(item.entry.title)")
                .disabled(!auth.signedIn)
                .opacity(auth.signedIn ? 1 : 0.45)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 20))
        .contextMenu {
            if index > 0 {
                Button("Move Earlier") { controller.moveQueueItem(from: item.index, to: item.index - 1) }
            }
            if index + 1 < rows.count {
                Button("Move Later") { controller.moveQueueItem(from: item.index, to: item.index + 1) }
            }
        }
        .accessibilityAction(named: Text("Move Earlier")) {
            guard index > 0 else { return }
            controller.moveQueueItem(from: item.index, to: item.index - 1)
        }
        .accessibilityAction(named: Text("Move Later")) {
            guard index + 1 < rows.count else { return }
            controller.moveQueueItem(from: item.index, to: item.index + 1)
        }
        .onDrop(of: [.text], delegate: QueueReorderDelegate(section: section, rows: rows, destIndex: index) { from, dest in
            move(IndexSet(integer: from), dest, rows: rows)
        })
    }

    private var autoplayStart: Int { controller.autoplaySectionStart }

    /// Upcoming manual rows — never includes AutoPlay, never the playing track.
    private var manualUpcoming: [QueueRow] {
        rows(in: controller.firstMovableQueueIndex..<autoplayStart)
    }

    private var autoplayUpcoming: [QueueRow] {
        rows(in: autoplayStart..<controller.queue.count)
    }

    private func rows(in range: Range<Int>) -> [QueueRow] {
        guard range.lowerBound < range.upperBound else { return [] }
        return range.compactMap { index in
            guard controller.queue.indices.contains(index) else { return nil }
            return QueueRow(index: index, entry: controller.queue[index])
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(entry: controller.current, side: 56)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.current?.title ?? "Nothing playing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(controller.current?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if auth.signedIn, controller.current?.videoId != nil {
                GlassCircleButton(
                    icon: controller.isLiked ? .bchHeartFilled : .bchHeart,
                    label: controller.isLiked ? "Remove Like" : "Like"
                ) { controller.toggleLike() }
            }
            Menu {
                if let current = controller.current {
                    SongActionButtons(entry: current, showSleepTimer: true, showDebugLog: true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 24)
    }

    /// What the row-motion animation tracks: every move changes it, nothing
    /// else does.
    private var queueSignature: String {
        (manualUpcoming.map(\.id) + autoplayUpcoming.map(\.id)).joined(separator: "|")
    }

    private func move(_ source: IndexSet, _ dest: Int, rows: [QueueRow]) {
        guard let fromLocal = source.first, rows.indices.contains(fromLocal) else { return }
        let fromQueue = rows[fromLocal].index
        let clampedDest = min(max(dest, 0), rows.count)
        let toQueue: Int
        if clampedDest >= rows.count {
            toQueue = (rows.last?.index ?? fromQueue) + 1
        } else {
            toQueue = rows[clampedDest].index
        }
        controller.moveQueue(from: IndexSet(integer: fromQueue), to: toQueue)
    }

    private func remove(_ offsets: IndexSet, rows: [QueueRow]) {
        let indices = IndexSet(offsets.compactMap { rows.indices.contains($0) ? rows[$0].index : nil })
        controller.removeFromQueue(at: indices)
    }
}

/// Reorders within one queue section from the row's drag handle, like
/// upstream: a drag never leaves its section, and neighbours trade slots
/// live as the held row crosses them. The payload carries its section tag so
/// a drop onto the other section's rows is ignored, not misfiled.
private struct QueueReorderDelegate: DropDelegate {
    let section: Int
    let rows: [QueueRow]
    let destIndex: Int
    let onMove: (Int, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let parts = text.split(separator: ":").map(String.init).compactMap(Int.init)
            guard parts.count == 2, parts[0] == section else { return }
            let from = parts[1]
            guard rows.indices.contains(from), rows.indices.contains(destIndex), from != destIndex else { return }
            Task { @MainActor in onMove(from, destIndex) }
        }
    }

    func performDrop(info: DropInfo) -> Bool { true }
}

private struct QueueRow: Identifiable {
    let index: Int
    let entry: QueueEntry
    var id: String { "\(index)-\(entry.id)" }
}
