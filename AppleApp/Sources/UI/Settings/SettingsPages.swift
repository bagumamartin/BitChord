import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct QualityPickerPage: View {
    let title: String
    @Binding var selection: String
    let options: [AudioQualityOption]

    var body: some View {
        List {
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Text(option.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == option.id {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

struct AutomixPerformancePage: View {
    @Binding var selection: String

    private let modes = [
        ("EFFICIENT", "Efficient", "1 inference worker · skips vocal analysis"),
        ("BALANCED", "Balanced", "Up to 2 inference workers · the default"),
        ("PERFORMANCE", "Performance", "Up to 4 inference workers · higher CPU use"),
    ]

    var body: some View {
        List {
            ForEach(modes, id: \.0) { mode in
                Button {
                    selection = mode.0
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.1)
                                .foregroundStyle(.primary)
                            Text(mode.2)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == mode.0 {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Automix Performance")
    }
}

struct SpotifyCanvasAuthView: View {
    @Binding var cookie: String

    var body: some View {
        Form {
            Section {
                SecureField("sp_dc cookie", text: $cookie)
                    .textContentType(.password)
            } header: {
                Text("Spotify Canvas Setup")
            } footer: {
                Text("Paste the sp_dc cookie from an open Spotify web session. BitChord uses it only to look up looping motion art. Leave blank to skip.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Spotify Canvas")
    }
}

// MARK: - Rows

struct AudioQualityOption: Identifiable {
    let id: String
    let title: String
    let detail: String

    static let stream: [AudioQualityOption] = [
        .init(id: "LOW", title: "Low", detail: String(localized: "Up to 64 kbps · about 29 MB per hour")),
        .init(id: "MEDIUM", title: "Medium", detail: String(localized: "Up to 128 kbps · about 58 MB per hour")),
        .init(id: "HIGH", title: "High", detail: String(localized: "Best compressed audio from enabled sources · YouTube fallback")),
        .init(id: "LOSSLESS", title: String(localized: "Highest Available"), detail: String(localized: "Prefer lossless and Hi-Res · fall back to available audio")),
    ]

    static let download: [AudioQualityOption] = [
        .init(id: "STANDARD", title: "Standard", detail: "128 kbps AAC"),
        .init(id: "HIGH", title: "High", detail: "Best AAC the source will give"),
        .init(id: "LOSSLESS", title: String(localized: "Highest Available"), detail: String(localized: "Keeps lossless when available · otherwise saves the available format")),
    ]

    static func label(_ id: String, in options: [AudioQualityOption]) -> String {
        options.first { $0.id == id }?.title ?? id.capitalized
    }
}
