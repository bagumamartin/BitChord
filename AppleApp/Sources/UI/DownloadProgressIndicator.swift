import SwiftUI

struct DownloadProgressIndicator: View {
    let activity: DownloadActivity
    var body: some View {
        HStack(spacing: 5) {
            switch activity.phase {
            case .transferring:
                if let fraction = activity.fraction {
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
                        Circle().trim(from: 0, to: fraction).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    }.frame(width: 15, height: 15)
                    Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit())
                } else { ProgressView().controlSize(.mini) }
            case .resolving, .verifying: ProgressView().controlSize(.mini)
            case .queued: Image(systemName: "clock.arrow.circlepath")
            case .waitingForNetwork, .waitingForWiFi: Image(systemName: "wifi.slash")
            case .saved: Image(systemName: "arrow.down.circle.fill")
            case .failed: Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.red)
            case .cancelled: Image(systemName: "xmark.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.label)
        .help(activity.detail ?? activity.label)
    }
}
