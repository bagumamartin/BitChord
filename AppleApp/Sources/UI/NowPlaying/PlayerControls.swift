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

/// Frosted circular chrome used for dismiss / lyrics / queue.
/// A round, material-backed icon button for the player's secondary controls.
///
/// [label] is required rather than optional: every one of these is an
/// icon-only button, and without it VoiceOver announced the asset name. The
/// glyphs are upstream's own, per UI spec §6.
struct GlassCircleButton: View {
    var system: String? = nil
    var icon: ImageResource? = nil
    var selected: Bool = false
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(icon).resizable().scaledToFit().frame(width: 15, height: 15)
                } else if let system {
                    Image(systemName: system).scaledFont(size: 15, weight: .semibold)
                }
            }
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            // Upstream `CircleGlyph`'s disc: 18% white, 34% when active.
            .background(.white.opacity(selected ? 0.34 : 0.18), in: Circle())
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.18), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Fixed-size volume control. Intrinsic width so the capsule glass stays a pill.
struct ToolbarVolumeSlider: View {
    @Binding var volume: Double

    private let trackWidth: CGFloat = 112

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .scaledFont(size: 12, weight: .semibold)
                .frame(width: 16, height: 16)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: trackWidth, height: 4)
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: max(4, trackWidth * volume), height: 4)
                Circle()
                    .fill(.primary)
                    .frame(width: 10, height: 10)
                    .offset(x: min(max(0, trackWidth * volume - 5), trackWidth - 10))
            }
            .frame(width: trackWidth, height: 14)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        volume = min(max(0, g.location.x / trackWidth), 1)
                    }
            )
        }
        .padding(.horizontal, 8)
        .frame(width: 176, height: 22)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(1, volume + 0.1)
            case .decrement: volume = max(0, volume - 0.1)
            default: break
            }
        }
    }
}

#if os(iOS)
struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else

struct AirPlayRouteButton: NSViewRepresentable {
    func makeNSView(context: Context) -> SquareRoutePicker {
        SquareRoutePicker()
    }
    func updateNSView(_ nsView: SquareRoutePicker, context: Context) {}
}

/// AVRoutePickerView's intrinsic size is not square, so toolbar glass becomes
/// a squircle. Pin it to a 22pt box so the item can be a circle.
final class SquareRoutePicker: NSView {
    private let picker = AVRoutePickerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picker.isRoutePickerButtonBordered = false
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentHuggingPriority(.required, for: .vertical)
        addSubview(picker)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func layout() {
        super.layout()
        picker.frame = bounds
    }
}
#endif
