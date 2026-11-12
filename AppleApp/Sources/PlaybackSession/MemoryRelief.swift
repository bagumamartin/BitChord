import Darwin
import Foundation

/// Hands freed heap pages back to the system after an analysis burst.
///
/// A track change decodes whole tracks for analysis and frees them seconds
/// later, but the allocator keeps those large regions mapped ("Malloc Large
/// (empty)", over 200 MB measured) and they keep counting toward the app's
/// footprint until memory pressure arrives. Asking for relief once the burst
/// is over brings the footprint back down without waiting for the system to
/// complain. Debounced: several bursts ending together cost one pass.
enum MemoryRelief {
    private static let queue = DispatchQueue(label: "bitchord.memory-relief", qos: .utility)
    nonisolated(unsafe) private static var pending: DispatchWorkItem?

    static func soon(after seconds: Double = 3) {
        queue.async {
            pending?.cancel()
            let work = DispatchWorkItem { _ = malloc_zone_pressure_relief(nil, 0) }
            pending = work
            queue.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }
}

