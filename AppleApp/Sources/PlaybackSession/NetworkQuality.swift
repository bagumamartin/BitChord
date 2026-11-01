import Foundation
import Network
import Observation
import BitChordShared

/// Wi-Fi vs cellular (metered) for per-network quality ceilings.
@MainActor
@Observable
final class NetworkQuality {
    static let shared = NetworkQuality()
    private(set) var metered = false
    private(set) var connected = true
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// Which interface carries traffic, and whether it is up. A change here is
    /// what strands a request on a dead socket (leaving Wi-Fi, a VPN coming up).
    @ObservationIgnored private var pathSignature: String?
    /// Bumped on every real path change, for anything that wants to retry.
    private(set) var pathChanges = 0

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            let signature = "\(path.status)|" + path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.connected
                self.metered = expensive; self.connected = path.status == .satisfied
                StreamDownloadBridge.shared.networkStatus(available: self.connected)
                AppSettings.shared.setMeteredConnection(value: KotlinBoolean(bool: expensive))
                DownloadStore.shared.networkPolicyChanged()
                if let previous = self.pathSignature, previous != signature {
                    self.pathChanges += 1
                    // Active streams drop requests on the old path and resume at
                    // their offsets, rather than waiting out a socket timeout.
                    if self.connected && wasConnected { StreamDownloadBridge.shared.networkChanged() }
                }
                self.pathSignature = signature
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    var maxKbps: Swift.Int32 {
        AppSettings.shared.effectiveAudioQuality(metered: metered).maxKbps
    }

    var canvasAllowed: Bool {
        let enabled = PlatformSettings.shared.getBoolean(key: "animated_canvas", default: true)
        if !enabled { return false }
        if metered {
            return PlatformSettings.shared.getBoolean(key: "canvas_over_cellular", default: false)
        }
        return true
    }
}
