import SwiftUI
import BitChordShared

/// Whether an Automix model download may use the connection in hand.
@MainActor
enum AutomixModelsPolicy {
    static var isMetered: Bool { NetworkQuality.shared.metered }

    static var wifiOnly: Bool {
        PlatformSettings.shared.getBoolean(key: "wifi_only_downloads", default: true)
    }

    /// True when the transfer may start right now.
    static var allowMetered: Bool { !(isMetered && wifiOnly) }
}

/// One model, its state, and the action that state calls for in Settings.
struct AutomixModelRow: View {
    let id: AutomixModelStore.ModelID
    let store: AutomixModelStore

    var body: some View {
        let spec = store.spec(id)
        let status = store.status(of: id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: iconName)
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.displayName)
                        .font(.body.weight(.medium))
                    Text(spec.sizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if status.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else if store.isUsingPreviousGraph(id) {
                    Label("Update available", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Text(spec.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isUsingPreviousGraph(id) {
                Text("Update available. Using the previous version")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls(spec: spec, status: status)
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch id {
        case .beat: return "metronome"
        case .vocals: return "waveform.badge.mic"
        }
    }

    private var iconColor: Color {
        switch id {
        case .beat: return .blue
        case .vocals: return .purple
        }
    }

    @ViewBuilder
    private func controls(spec: AutomixModelStore.ModelSpec, status: AutomixModelStore.Status) -> some View {
        switch status {
        case .notInstalled:
            action("Download") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }

        case .paused(let bytes):
            HStack(spacing: 10) {
                Text("Paused at \(AutomixModelStore.bytes(bytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                action("Resume") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }
                Button("Discard") { store.remove(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .tint(iconColor)
                HStack {
                    let downloaded = Int64(Double(spec.byteCount) * progress)
                    Text("\(AutomixModelStore.bytes(downloaded)) of \(spec.sizeText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel") { store.cancel(id) }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking download…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .installed:
            HStack(spacing: 12) {
                Button("Verify") { store.verify(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                Button("Remove") { store.remove(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }

        case .outdated:
            HStack(spacing: 12) {
                action("Update") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }
                Button("Remove") { store.remove(id) }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }

        case .blockedByWifi:
            HStack(spacing: 10) {
                Text("Waiting for Wi‑Fi")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                action("Download anyway") { store.start(id, allowMetered: true) }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                action("Try again") { store.start(id, allowMetered: AutomixModelsPolicy.allowMetered) }
            }
        }
    }

    @ViewBuilder
    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

/// An elevated card representation of an Automix model for modal prompt sheets.
private struct AutomixModelCard: View {
    let id: AutomixModelStore.ModelID
    let store: AutomixModelStore

    var body: some View {
        let spec = store.spec(id)
        let status = store.status(of: id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Leading Icon Tile
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBgColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: iconName)
                        .scaledFont(size: 18, weight: .semibold)
                        .foregroundStyle(iconBgColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cardTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(spec.sizeText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }

                    Text(cardSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                // Trailing Status Indicator / Action
                trailingIndicator(spec: spec, status: status)
            }

            // Description
            Text(cardDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Progress or Error Bar if active
            if case .downloading(let progress) = status {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .tint(iconBgColor)
                    HStack {
                        let downloadedBytes = Int64(Double(spec.byteCount) * progress)
                        Text("\(AutomixModelStore.bytes(downloadedBytes)) of \(spec.sizeText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(iconBgColor)
                    }
                }
            } else if case .verifying = status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying checksum…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case .outdated = status {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Update available. Using the previous version")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if case .blockedByWifi = status {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Waiting for Wi-Fi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download anyway") {
                        store.start(id, allowMetered: true)
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            } else if case .failed(let message) = status {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") {
                        store.start(id, allowMetered: AutomixModelsPolicy.allowMetered)
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                #if os(macOS)
                .fill(Color(nsColor: .controlBackgroundColor))
                #else
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                #endif
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }

    private var cardTitle: String {
        switch id {
        case .beat: return "Beat Detection"
        case .vocals: return "Vocal Detection"
        }
    }

    private var cardSubtitle: String {
        switch id {
        case .beat: return "Beat This! AI"
        case .vocals: return "open-unmix umxhq"
        }
    }

    private var cardDescription: String {
        switch id {
        case .beat:
            return "Analyzes beat grids and downbeats so song transitions land perfectly in time with the music."
        case .vocals:
            return "Finds the singing at the start and end of each track so two vocals do not overlap during a transition."
        }
    }

    private var iconName: String {
        switch id {
        case .beat: return "metronome"
        case .vocals: return "waveform.badge.mic"
        }
    }

    private var iconBgColor: Color {
        switch id {
        case .beat: return .blue
        case .vocals: return .purple
        }
    }

    @ViewBuilder
    private func trailingIndicator(spec: AutomixModelStore.ModelSpec, status: AutomixModelStore.Status) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 20)
                .foregroundStyle(.green)
        case .downloading:
            Button {
                store.cancel(id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel download")
        case .verifying:
            EmptyView()
        case .outdated:
            Button {
                store.start(id, allowMetered: AutomixModelsPolicy.allowMetered)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .scaledFont(size: 22)
                    .foregroundStyle(iconBgColor)
            }
            .buttonStyle(.plain)
            .help("Update \(spec.displayName)")
        case .notInstalled, .paused, .blockedByWifi, .failed:
            Button {
                store.start(id, allowMetered: AutomixModelsPolicy.allowMetered)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .scaledFont(size: 22)
                    .foregroundStyle(iconBgColor)
            }
            .buttonStyle(.plain)
            .help("Download \(spec.displayName)")
        }
    }
}

/// The first-run and settings offer for on-device Automix analysis models.
///
/// Redesigned to Apple HIG standards: responsive layout across all device widths,
/// hero imagery, on-device privacy transparency, simultaneous model downloads,
/// and background completion support.
struct AutomixModelsSheet: View {
    /// Called when the listener declines, so the app remembers not to reprompt on launch.
    var onDecline: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toast: ToastCenter?

    private let store = AutomixModelStore.shared

    private var allInstalled: Bool {
        AutomixModelStore.ModelID.allCases.allSatisfy { store.status(of: $0).isInstalled }
    }

    private var anyBusy: Bool {
        store.anyBusy
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        // Hero Header
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.98, green: 0.35, blue: 0.55),
                                                Color(red: 0.65, green: 0.25, blue: 0.95)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 64, height: 64)
                                    .shadow(color: Color.purple.opacity(0.3), radius: 12, y: 6)

                                Image(systemName: "waveform.badge.sparkles")
                                    .scaledFont(size: 28, weight: .semibold)
                                    .foregroundStyle(.white)
                            }
                            .padding(.top, 16)

                            VStack(spacing: 6) {
                                Text("Automix Transitions")
                                    .font(.title2.weight(.bold))
                                    .multilineTextAlignment(.center)

                                Text("BitChord analyzes your tracks on-device to match beats, time crossfades, and prevent vocal clashes between songs.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                            }
                        }

                        // Model Cards
                        VStack(spacing: 12) {
                            AutomixModelCard(id: .beat, store: store)
                            AutomixModelCard(id: .vocals, store: store)
                        }
                        .padding(.horizontal, 20)

                        // Privacy & Storage Footnote
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("46.7 MB of models · Runs 100% on-device · Private")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text("Models are downloaded once and verified via SHA-256. Manage anytime in Settings.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }
                }

                Divider()

                // Actions Footer
                footerActions
            }
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if !allInstalled && !anyBusy {
                            onDecline()
                        }
                        dismiss()
                    }
                }
            }
            .frame(width: 500, height: 560)
            #else
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if !allInstalled && !anyBusy {
                            onDecline()
                        }
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .presentationDetents([.fraction(0.85), .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            #endif
        }
        .task { store.refresh() }
        .onChange(of: store.status) { old, new in
            announce(from: old, to: new)
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            Text(AutomixModelsPolicy.isMetered && AutomixModelsPolicy.wifiOnly ? "Wi-Fi recommended" : "Wi-Fi or Ethernet")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !allInstalled && !anyBusy {
                Button("Not Now") {
                    onDecline()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if allInstalled {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else if anyBusy {
                Button("Continue in Background") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Download Models (~46.7 MB)") {
                    downloadAllMissing()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        #else
        VStack(spacing: 10) {
            if allInstalled {
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if anyBusy {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("Downloading in Background — Done")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    downloadAllMissing()
                } label: {
                    Text("Download Models (~46.7 MB)")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onDecline()
                    dismiss()
                } label: {
                    Text("Not Now")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        #endif
    }

    private func downloadAllMissing() {
        for id in AutomixModelStore.ModelID.allCases {
            let status = store.status(of: id)
            if !status.isInstalled && !status.isBusy {
                store.start(id, allowMetered: AutomixModelsPolicy.allowMetered)
            }
        }
    }

    /// Only status transitions are announced.
    private func announce(
        from old: [AutomixModelStore.ModelID: AutomixModelStore.Status],
        to new: [AutomixModelStore.ModelID: AutomixModelStore.Status]
    ) {
        for id in AutomixModelStore.ModelID.allCases {
            let spec = store.spec(id)
            let was = old[id] ?? .notInstalled
            let now = new[id] ?? .notInstalled
            guard was != now else { continue }
            switch now {
            case .installed:
                toast?.show("\(spec.displayName) installed")
            case .failed(let message):
                toast?.show(message, kind: .failure)
            default:
                break
            }
        }
    }
}

/// The same rows in Settings, for anyone who declined or wants to change the set.
struct AutomixModelsPage: View {
    private let store = AutomixModelStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(AutomixModelStore.ModelID.allCases) { id in
                    AutomixModelRow(id: id, store: store)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Downloaded once and kept in BitChord's storage. Removing a model takes effect immediately: Automix falls back to tempo analysis without the beat model, and stops watching for vocal clashes without the vocal one.")
            }
            Section {
                if store.totalBytesOnDisk > 0 {
                    LabeledContent("On disk", value: AutomixModelStore.bytes(store.totalBytesOnDisk))
                }
                LabeledContent("Source", value: "GitHub releases")
                LabeledContent("Licence", value: "MIT (beat + vocals)")
            } footer: {
                Text("Beat This! (beat and downbeat detection) and open-unmix umxhq (vocal detection). Both are downloaded once and verified against a pinned checksum.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automix Models")
        .task { store.refresh() }
    }
}
