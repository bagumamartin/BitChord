import SwiftUI

/// A compact in-app index of the third-party code and resources shipped by the
/// Apple app. Full bundled license texts are shown inline where available.
struct LicenseAcknowledgementsView: View {
    private let acknowledgements: [Acknowledgement] = [
        .init(
            name: "BitChord and InnerTubeX",
            detail: "The Apple port is derived from BitChord by Kushagra Singh. YouTube Music extraction uses the vendored InnerTubeX client.",
            license: "GPL-3.0",
            file: "GPL-3.0.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/LICENSE"
        ),
        .init(
            name: "Orchard analyzer code",
            detail: "Selected tempo and audio-analysis files are ported from Orchard by SFG545 through BitChord's Android implementation.",
            license: "AGPL-3.0-or-later",
            file: "AGPL-3.0.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/LICENSES/AGPL-3.0.txt"
        ),
        .init(
            name: "CPAL audio I/O",
            detail: "Cross-platform audio I/O used by the native audio framework.",
            license: "Apache-2.0",
            file: "Apache-2.0.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/LICENSES/third-party/Apache-2.0-CPAL.txt"
        ),
        .init(
            name: "objc2 Apple audio bindings",
            detail: "CoreAudio and CoreFoundation bindings used by the macOS native audio path. The upstream project notes that Apple SDK terms may also apply to SDK-derived bindings.",
            license: "MIT (selected option)",
            file: "MIT-objc2.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/LICENSES/third-party/MIT-objc2.txt"
        ),
        .init(
            name: "Symphonia and UniFFI",
            detail: "Audio format decoding and the native Swift/Kotlin binding layer.",
            license: "MPL-2.0",
            file: "MPL-2.0.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/LICENSES/third-party/MPL-2.0-Symphonia.txt"
        ),
        .init(
            name: "Opus decoder",
            detail: "The Symphonia Opus adapter selects its MIT license option and bundles libopus.",
            license: "BSD-3-Clause",
            file: "BSD-3-Clause-Opus.txt",
            url: "https://github.com/bagumamartin/BitChord/tree/main/LICENSES/third-party"
        ),
        .init(
            name: "Symphonia Opus adapter",
            detail: "The adapter's dual-licensed release is used under its MIT option.",
            license: "MIT",
            file: "MIT-Symphonia-Opus-Adapter.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/LICENSES/third-party/MIT-Symphonia-Opus-Adapter.txt"
        ),
        .init(
            name: "Native dependency data and zlib-rs",
            detail: "Apple-targeted Cargo dependencies include Unicode data, webpki root certificates and zlib-rs under these additional terms.",
            license: "Unicode-3.0, CDLA-Permissive-2.0 and Zlib",
            file: "Cargo-data-licenses.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/AppleApp/Resources/AudioLicenses/Cargo-data-licenses.txt"
        ),
        .init(
            name: "Kotlin shared framework",
            detail: "The shared framework uses Kotlin Multiplatform, Ktor, kotlinx serialization/coroutines, KMP-NativeCoroutines and QuickJS-KT. Versions and source sets are listed in the Gradle manifests.",
            license: "Apache-2.0",
            file: "Apache-2.0.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/THIRD_PARTY_NOTICES.md"
        ),
        .init(
            name: "Sparkle updater (macOS)",
            detail: "Sparkle's full notice includes its MIT license and the notices for bundled external components.",
            license: "MIT and included external license terms",
            file: "Sparkle-LICENSE.txt",
            url: "https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE"
        ),
        .init(
            name: "YouTube player solver",
            detail: "The embedded yt-dlp/ejs scripts run locally. The core is Unlicense; the bundled library includes meriyah and astring notices.",
            license: "Unlicense, ISC and MIT",
            file: "yt-ejs-dependencies.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/THIRD_PARTY_NOTICES.md"
        ),
        .init(
            name: "Automix model weights",
            detail: "The Beat This! and open-unmix vocal graphs are downloaded on demand from the project's GitHub releases; both are MIT-licensed. Beat This! notes that some training data may carry separate terms.",
            license: "MIT",
            file: "MIT-Model-Weights.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/THIRD_PARTY_NOTICES.md"
        ),
        .init(
            name: "SoX Resampler (libsoxr)",
            detail: "Bundled native resampling library by Rob Sykes.",
            license: "LGPL-2.1-or-later",
            file: "libsoxr-LGPL-2.1.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/native-core/vendor/soxr-0.1.3"
        ),
        .init(
            name: "EBU R128",
            detail: "Loudness measurement library by EBU R128 contributors.",
            license: "MIT",
            file: "ebur128-MIT.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/AppleApp/Resources/AudioLicenses/ebur128-MIT.txt"
        ),
        .init(
            name: "LastWave clarity specifications",
            detail: "The clarity filter specifications and preset stage trims in the native audio engine are ported from LastWave-native.",
            license: "GPL-3.0",
            file: "Lastwave-license.txt",
            url: "https://github.com/Clash-Projects/LastWave-native/blob/main/LICENSE"
        ),
        .init(
            name: "Phosphor Icons",
            detail: "Phosphor icon artwork used by the interface.",
            license: "MIT",
            file: "PhosphorIcons-MIT.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/AppleApp/Resources/AudioLicenses/PhosphorIcons-MIT.txt"
        ),
        .init(
            name: "Icons and translated strings",
            detail: "Settings uses Material Icons and Phosphor Icons. Localization includes strings carried over from upstream where the English source text matches.",
            license: "Apache-2.0, MIT and upstream GPLv3 notices",
            file: "material-icons.txt",
            url: "https://github.com/bagumamartin/BitChord/blob/main/THIRD_PARTY_NOTICES.md"
        ),
    ]

    var body: some View {
        List {
            Section {
                Text("BitChord is derived from the Android project by Kushagra Singh. The Apple-platform port and original additions are Copyright © 2026 Martin BAGUMA.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Link("Full third-party notices", destination: URL(string: "https://github.com/bagumamartin/BitChord/blob/main/THIRD_PARTY_NOTICES.md")!)
            }

            Section("Acknowledgements and licenses") {
                ForEach(acknowledgements) { acknowledgement in
                    DisclosureGroup {
                        Text(acknowledgement.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        LabeledContent("License", value: acknowledgement.license)
                        if let file = acknowledgement.file {
                            BundledLicenseText(fileName: file)
                        }
                        Link("Source and full notice", destination: URL(string: acknowledgement.url)!)
                    } label: {
                        Text(acknowledgement.name)
                    }
                }
            }
        }
        .navigationTitle("Open-source licenses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct Acknowledgement: Identifiable {
    var name: String
    var detail: String
    var license: String
    var file: String?
    var url: String

    var id: String { name }
}

private struct BundledLicenseText: View {
    let fileName: String
    @State private var contents: String?

    var body: some View {
        Group {
            if let contents {
                ScrollView(.horizontal) {
                    Text(contents)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else {
                Text("The license text is available from the source link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            guard contents == nil,
                  let url = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "AudioLicenses")
            else { return }
            contents = try? String(contentsOf: url, encoding: .utf8)
        }
    }
}
