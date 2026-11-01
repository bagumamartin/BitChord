import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import BitChordShared
import UniformTypeIdentifiers

/// Explore tab — upstream shows mood and genre categories here.
struct ExploreView: View {
    @State private var moods = MoodGenreLoader()
    @Environment(AuthController.self) private var auth
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        PageStack {
            content
                .navigationTitle("Explore")
                .toolbar {
                    #if os(iOS)
                    TopBarLeadingItems()
                    ToolbarItem(placement: .topBarTrailing) { TopBarAccountButton() }
                    #endif
                }
                .refreshable {
                    await moods.load(force: true)
                }
                .task(id: auth.sessionEpoch) {
                    await moods.load(force: false)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch moods.phase {
        case .loading:
            ScrollView { moodGrid.padding(.horizontal, 24).padding(.vertical, 20) }
        case .failed(let message):
            EmptyStateView(
                icon: Image(.bchExplore),
                title: "Nothing to explore right now",
                subtitle: message,
                buttonTitle: "Retry"
            ) { Task { await moods.load(force: true) } }
        case .loaded:
            ScrollView {
                moodGrid
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
    }

    @State private var gridWidth: CGFloat = 0

    @ViewBuilder
    private var moodGrid: some View {
        switch moods.phase {
        case .loading:
            // Column-aware placeholder rows at the real tile aspect, so the
            // grid keeps the shape it is about to have.
            LazyVGrid(columns: moodColumns, spacing: 12) {
                ForEach(0..<(moodColumnCount * 6), id: \.self) { _ in
                    MoodTileSkeleton()
                }
            }
        case .failed:
            EmptyView()
        case .loaded(let sections):
            // One flat grid, not one grid per section: upstream flattened the
            // page in 3d2b35ce and dedupes by (browseId, params) — the same
            // pair a tile's id is built from — because a category that the
            // server lists twice would paint twice.
            let tiles = sections.flatMap(\.items).dedupedById()
            LazyVGrid(columns: moodColumns, spacing: 12) {
                ForEach(tiles) { item in
                    PushLink {
                        MoodGenrePlaylistsView(category: item)
                    } label: {
                        MoodTile(category: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        }
    }

    /// Upstream's `moodColumns`: as many 220pt-minimum columns as the row
    /// fits, between two and six, so a phone still gets its two and a wide
    /// window stops growing at six.
    private var moodColumnCount: Int {
        let row = gridWidth - 48
        let count = Int((row + 12) / (220 + 12))
        return min(6, max(2, count))
    }

    private var moodColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: moodColumnCount)
    }
}

/// One category tile: a solid stripe down the left and the category's cover
/// filling the rest, redrawn as a duotone of the stripe's colour so the tile
/// reads as one tinted sleeve rather than a photo pasted onto a swatch —
/// upstream's `MoodGenreSleeve` (1.72 aspect, 18pt corners, title over a
/// legibility wash at the top-start).
private struct MoodTile: View {
    let category: MoodGenre

    /// How much of the tile the solid stripe covers before the artwork starts.
    private let stripeFraction: CGFloat = 0.28

    // MARK: Tone (upstream `moodTone`)

    /// Kotlin String.hashCode uses UTF-16 units and a 31 multiplier — the same
    /// hash picks the fallback for the same title on every platform.
    private var colorIndex: Int {
        let hash = category.title.utf16.reduce(Int32(0)) { value, unit in
            value &* 31 &+ Int32(unit)
        }
        return Int((UInt32(bitPattern: hash) & 0x7fff_ffff) % 8)
    }

    private func argb(_ value: Int64) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: Double((value >> 24) & 0xFF) / 255)
    }

    private func lerp(_ from: (Double, Double, Double), to: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        (from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t, from.2 + (to.2 - from.2) * t)
    }

    private var baseRGB: (Double, Double, Double) {
        if let stripeColor = category.stripeColor {
            let value = UInt64(bitPattern: stripeColor)
            return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        // For a button that came without YouTube's colour: muted, never neon.
        let colors: [(Int, Int, Int)] = [
            (0xCC, 0x6A, 0x55), (0xC0, 0x7A, 0x92), (0x9C, 0x8A, 0xC0), (0x80, 0x90, 0xC8),
            (0xD0, 0xA0, 0x60), (0x6A, 0x88, 0xB0), (0x7A, 0xAE, 0xD0), (0x86, 0xB8, 0x90),
        ]
        let (r, g, b) = colors[colorIndex]
        return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    private var stripeRGB: (Double, Double, Double) {
        // YouTube's palette is already pastel; a touch of black keeps it from
        // glowing against the page.
        lerp(baseRGB, to: (0, 0, 0), 0.08)
    }

    private var shadowRGB: (Double, Double, Double) {
        lerp(baseRGB, to: (0, 0, 0), 0.68)
    }

    private var highlightRGB: (Double, Double, Double) {
        lerp(baseRGB, to: (1, 1, 1), 0.32)
    }

    private var placeholderRGB: (Double, Double, Double) {
        lerp(shadowRGB, to: highlightRGB, 0.45)
    }

    private func rgbColor(_ rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            rgbColor(stripeRGB)
            // The duotone: a grayscale cover multiplied by the ramp's span and
            // added over the shadow tone is exactly the luminance ramp
            // upstream's ColorMatrix maps, composed from two blend modes.
            ZStack {
                rgbColor(placeholderRGB)
                if let url = category.thumbnailUrl {
                    // The ramp's span: highlight minus shadow, per channel,
                    // which the grayscale cover's luminance walks.
                    let span = (
                        max(0, highlightRGB.0 - shadowRGB.0),
                        max(0, highlightRGB.1 - shadowRGB.1),
                        max(0, highlightRGB.2 - shadowRGB.2)
                    )
                    ArtworkView(url: url, data: nil, fill: true)
                        .grayscale(1)
                        .colorMultiply(rgbColor(span))
                        .blendMode(.plusLighter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, stripeFraction * 300)
            // Pale stripes would swallow white type; a soft wash under the
            // title keeps it legible.
            LinearGradient(
                colors: [.black.opacity(0.24), .clear],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.62)
            )
            Text(category.title)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 1)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .aspectRatio(1.72, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
        .accessibilityLabel(category.title)
    }
}

/// The loading tile: the real aspect, the real corner, the shared pulse.
private struct MoodTileSkeleton: View {
    var body: some View {
        SkeletonBlock(height: 400, cornerRadius: 18)
            .aspectRatio(1.72, contentMode: .fit)
    }
}

private extension Array where Element == MoodGenre {
    /// First occurrence wins, keyed the way a tile identifies itself.
    func dedupedById() -> [MoodGenre] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
