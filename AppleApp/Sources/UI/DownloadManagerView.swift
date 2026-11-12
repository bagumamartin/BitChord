import SwiftUI

/// Upstream `DownloadManagerSheet`: every track asked for, what became of it,
/// and a way out of the ones still going.
///
/// Per-job Cancel/Retry and Cancel All / Clear all act on the real
/// `DownloadStore`. The destructive ones — deleting a finished file, clearing
/// the on-device library — go through `ConfirmationDialog` first, because a
/// tap that destroys a file is not a tap that should land by accident.
struct DownloadManagerView: View {
    private var store: DownloadStore { DownloadStore.shared }
    @Environment(ToastCenter.self) private var toast
    @Environment(PlaybackController.self) private var controller
    @State private var searchText = ""
    @State private var cachedBytes: Int64 = 0
    @State private var offlinePlayback = OfflinePlaybackPolicy.isEnabled

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleJobs: [DownloadStore.Job] {
        guard !query.isEmpty else { return store.jobs }
        return store.jobs.filter { "\($0.title) \($0.entry.artist)".localizedCaseInsensitiveContains(query) }
    }
    private var activeJobs: [DownloadStore.Job] { visibleJobs.filter { $0.status == .queued || $0.status == .running } }
    private var failedJobs: [DownloadStore.Job] { visibleJobs.filter { $0.status == .failed } }
    private var completedJobs: [DownloadStore.Job] { visibleJobs.filter { $0.status == .done } }
    private var visibleItems: [DownloadedTrack] {
        guard !query.isEmpty else { return store.items }
        return store.items.filter { "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(query) }
    }
    private var visibleCollections: [DownloadStore.Owner] {
        guard !query.isEmpty else { return store.collections }
        return store.collections.filter { owner in
            let pendingText = owner.requests.compactMap { id in store.jobs.first(where: { $0.id == id })?.entry }
                .map { "\($0.title) \($0.artist)" }.joined(separator: " ")
            let savedText = owner.browseId.map { browseId in
                store.savedEntries(for: browseId).map { "\($0.title) \($0.artist)" }.joined(separator: " ")
            } ?? ""
            let songText = pendingText + " " + savedText
            return "\(owner.title) \(songText)".localizedCaseInsensitiveContains(query)
        }
    }
    private var hasSearchMatches: Bool {
        !activeJobs.isEmpty || !failedJobs.isEmpty || !completedJobs.isEmpty || !visibleItems.isEmpty || !visibleCollections.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Offline playback") {
                    Toggle("Play saved audio only", isOn: $offlinePlayback)
                        .onChange(of: offlinePlayback) { _, enabled in
                            OfflinePlaybackPolicy.setEnabled(enabled)
                            if enabled { controller.offlinePlaybackEnabled() }
                        }
                    Text("Uses downloaded tracks and eligible cached audio. Turning this on immediately switches the current track to a saved copy when available; otherwise playback stops and offers Retry. The queue position is kept. This is separate from Wi-Fi-only downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Storage on this device") {
                    LabeledContent("Saved downloads", value: Self.size(store.downloadedBytes))
                    LabeledContent("Stream cache", value: Self.size(cachedBytes))
                    Text("Saved downloads stay until you remove them. The stream cache can be cleared and may be rebuilt during online playback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !query.isEmpty && !hasSearchMatches {
                    Text("No downloads match “\(query)”").foregroundStyle(.secondary)
                } else if store.jobs.isEmpty && store.items.isEmpty && store.collections.isEmpty {
                    Text("No downloads yet. Save a track from Now Playing or a collection menu.")
                        .foregroundStyle(.secondary)
                }
                if !visibleCollections.isEmpty {
                    Section("Downloaded collections") {
                        ForEach(visibleCollections) { owner in
                            VStack(alignment: .leading) {
                                Text(owner.title)
                                Text(store.progress(owner) + estimate(owner)).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Refresh") { Task { if let id = owner.browseId { _ = await store.downloadCollection(browseId: id) } } }
                                    Button("Retry") { store.retryOwner(owner) }
                                    Button("Remove", role: .destructive) { store.removeOwner(owner.id) }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if !activeJobs.isEmpty {
                    Section("Active (\(activeJobs.count))") {
                        ForEach(activeJobs) { job in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.title)
                                    Text(store.activity(for: job)?.label ?? label(job.status))
                                        .font(.caption)
                                        .foregroundStyle(job.status == .failed ? .red : .secondary)
                                    if let message = job.message, job.status == .failed {
                                        Text(message).font(.caption2).foregroundStyle(.red)
                                    }
                                }
                                Spacer()
                                if let activity = store.activity(for: job) { DownloadProgressIndicator(activity: activity) }
                                switch job.status {
                                case .queued, .running:
                                    Button("Cancel") {
                                        store.cancel(job.id)
                                        toast.show("Download cancelled", kind: .info)
                                    }
                                case .failed:
                                    Button("Retry") { retry(job) }
                                case .done:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
                if !failedJobs.isEmpty {
                    Section("Failed (\(failedJobs.count))") {
                        ForEach(failedJobs) { job in
                            jobRow(job)
                        }
                    }
                }
                if !completedJobs.isEmpty {
                    Section("Completed (\(completedJobs.count))") {
                        ForEach(completedJobs) { job in
                            jobRow(job)
                        }
                    }
                }
                if !visibleItems.isEmpty {
                    Section("On this device") {
                        ForEach(visibleItems) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    Text(item.artist).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    let item = item
                                    toast.requestConfirmation(ConfirmationRequest(
                                        title: "Delete this download?",
                                        message: "“\(item.title)” will be removed from this device. The stream stays in your library.",
                                        confirm: "Delete Download"
                                    ) {
                                        store.delete(item.path)
                                    })
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete \(item.title)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .searchable(text: $searchText, prompt: "Search downloads")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.activeCount > 0 {
                        Button("Cancel All") {
                            store.cancelAll()
                            toast.show("Downloads cancelled", kind: .info)
                        }
                    }
                    if store.failedCount > 0 || store.completedCount > 0 || !store.items.isEmpty {
                        Menu("Manage") {
                            if store.failedCount > 0 {
                                Button("Retry All Failed") {
                                    switch store.retryAllFailed() {
                                    case .started(let count): toast.show("Retrying \(count) failed downloads")
                                    case .waitingForWiFi(let count): toast.show("\(count) retries queued. Waiting for Wi-Fi.", kind: .info)
                                    case .waitingForNetwork(let count): toast.show("\(count) retries queued. Waiting for a connection.", kind: .info)
                                    case .noFailedJobs: toast.show("No failed downloads to retry", kind: .info)
                                    }
                                }
                            }
                            if store.completedCount > 0 || store.failedCount > 0 {
                                Button("Clear finished jobs") { store.clearFinishedJobs() }
                            }
                            if !store.items.isEmpty {
                                Button("Clear downloads on this device", role: .destructive) {
                                    let count = store.items.count
                                    toast.requestConfirmation(ConfirmationRequest(
                                        title: "Clear all downloads?",
                                        message: "\(count) downloaded \(count == 1 ? "file" : "files") will be removed from this device. Streams stay in your library.",
                                        confirm: "Clear All Downloads"
                                    ) {
                                        store.clearDownloads()
                                    })
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                store.refresh()
                Task { cachedBytes = await StreamFileCache.shared.entries().reduce(Int64(0)) { $0 + $1.bytes } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func label(_ status: DownloadStore.Job.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .running: "Downloading"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    @ViewBuilder private func jobRow(_ job: DownloadStore.Job) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(job.title)
                Text(job.message ?? label(job.status)).font(.caption)
                    .foregroundStyle(job.status == .failed ? .red : .secondary)
            }
            Spacer()
            if job.status == .failed {
                Button("Retry") { retry(job) }
            }
        }
    }

    private func retry(_ job: DownloadStore.Job) {
        switch store.retry(job.id) {
        case .started:
            toast.show("Retrying \(job.title)")
        case .blockedByWifiOnly:
            toast.show("Retry queued for \(job.title). Waiting for Wi-Fi. Turn off Wi-Fi-only downloads in Settings to use mobile data.", kind: .info)
        case .alreadyExists:
            toast.show("\(job.title) is already downloading or downloaded", kind: .info)
        case .ignoredLocalTrack:
            break
        }
    }

    private func estimate(_ owner: DownloadStore.Owner) -> String {
        var estimate: Int64 = 0
        var hasUnknown = false
        for id in owner.requests {
            if let bytes = store.storedBytes(for: id) {
                estimate += bytes
                continue
            }
            guard let job = store.jobs.first(where: { $0.id == id }), job.entry.durationSeconds > 0 else {
                hasUnknown = true
                continue
            }
            // Only estimate when the selected quality maps to a known cap.
            let bitrate: Int64
            switch job.quality {
            case "STANDARD": bitrate = 128
            case "HIGH": bitrate = 256
            default: hasUnknown = true; continue
            }
            estimate += Int64(job.entry.durationSeconds) * bitrate * 1000 / 8
        }
        if estimate == 0 { return " · size unknown" }
        return " · approx. \(Self.size(estimate))\(hasUnknown ? "+" : "")"
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
