import Foundation

/// All artwork surfaces share raw disk bytes and one coalesced network request.
actor ArtworkRequests {
    static let shared = ArtworkRequests()
    private let store: OfflineArtworkStore
    private let fetch: @Sendable (String, [String: String]) async -> Data?
    private var flights: [String: Task<Data?, Never>] = [:]
    init(store: OfflineArtworkStore = .shared, fetch: @escaping @Sendable (String, [String: String]) async -> Data? = { url, headers in
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint); request.timeoutInterval = 15
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try? await GuardedHTTP.shared.data(for: request)
    }) { self.store = store; self.fetch = fetch }
    func data(url: String, headers: [String: String]) async -> Data? {
        let key = OfflineArtworkStore.key(url: url, headers: headers)
        if let task = flights[key] { return await task.value }
        let task = Task<Data?, Never> { [store, fetch] in
            if LocalArtwork.isReference(url) { return await LocalArtwork.shared.data(for: url) }
            if let saved = await store.cachedData(url: url, headers: headers) { return saved }
            guard let data = await fetch(url, headers) else { return nil }
            return await store.cache(data: data, url: url, headers: headers)
        }
        flights[key] = task
        let data = await task.value
        flights[key] = nil
        return data
    }
}
