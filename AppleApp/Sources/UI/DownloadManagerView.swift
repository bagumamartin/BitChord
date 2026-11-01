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

    var body: some View {
        NavigationStack {
            List {
                if store.jobs.isEmpty && store.items.isEmpty {
                    Text("No downloads yet. Save a track from Now Playing or a collection menu.")
                        .foregroundStyle(.secondary)
                }
                if !store.collections.isEmpty {
                    Section("Downloaded collections") {
                        ForEach(store.collections) { owner in
                            VStack(alignment: .leading) {
                                Text(owner.title)
                                Text(store.progress(owner)).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Refresh") { Task { if let id = owner.browseId { _ = await store.downloadCollection(browseId: id) } } }
                                    Button("Retry") { store.retryOwner(owner) }
                                    Button("Remove", role: .destructive) { store.removeOwner(owner.id) }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if !store.jobs.isEmpty {
                    Section("In progress") {
                        ForEach(store.jobs) { job in
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
                                    Button("Retry") {
                                        switch store.retry(job.id) {
                                        case .started:
                                            toast.show("Downloading \(job.title)")
                                        case .blockedByWifiOnly:
                                            toast.show("Downloads are limited to Wi-Fi. Turn that off in Settings to use mobile data.", kind: .failure)
                                        case .alreadyExists:
                                            toast.show("\(job.title) is already downloading or downloaded", kind: .info)
                                        case .ignoredLocalTrack:
                                            break
                                        }
                                    }
                                case .done:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
                if !store.items.isEmpty {
                    Section("On this device") {
                        ForEach(store.items) { item in
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if store.activeCount > 0 {
                        Button("Cancel All") {
                            store.cancelAll()
                            toast.show("Downloads cancelled", kind: .info)
                        }
                    } else if store.jobs.contains(where: { $0.status == .done || $0.status == .failed }) || !store.items.isEmpty {
                        Menu("Clear") {
                            if store.jobs.contains(where: { $0.status == .done || $0.status == .failed }) {
                                Button("Clear completed jobs") {
                                    store.clearFinishedJobs()
                                }
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
            .onAppear { store.refresh() }
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
}
