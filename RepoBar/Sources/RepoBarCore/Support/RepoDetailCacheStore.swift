import Foundation

struct RepoDetailCache: Codable {
    var openPulls: Int?
    var openPullsFetchedAt: Date?
    var ciDetails: CIStatusDetails?
    var ciFetchedAt: Date?
    var latestActivity: ActivityEvent?
    var activityEvents: [ActivityEvent]?
    var activityFetchedAt: Date?
    var traffic: TrafficStats?
    var trafficFetchedAt: Date?
    var heatmap: [HeatmapCell]?
    var heatmapFetchedAt: Date?
    var latestRelease: Release?
    var releaseFetchedAt: Date?
    var discussionsEnabled: Bool?
    var discussionsCheckedAt: Date?
}

struct RepoDetailCacheStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseURL: URL?

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.baseURL = baseURL ?? Self.defaultBaseURL(fileManager: fileManager)
    }

    func load(apiHost: URL, owner: String, name: String) -> RepoDetailCache? {
        guard let url = cacheFileURL(apiHost: apiHost, owner: owner, name: name) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            return try self.decoder.decode(RepoDetailCache.self, from: data)
        } catch {
            try? self.fileManager.removeItem(at: url)
            return nil
        }
    }

    func save(_ cache: RepoDetailCache, apiHost: URL, owner: String, name: String) {
        guard let url = cacheFileURL(apiHost: apiHost, owner: owner, name: name) else { return }

        let folder = url.deletingLastPathComponent()
        do {
            try self.fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    func clear() {
        guard let baseURL else { return }

        try? self.fileManager.removeItem(at: baseURL)
    }

    private func cacheFileURL(apiHost: URL, owner: String, name: String) -> URL? {
        guard let baseURL else { return nil }

        let host = apiHost.host ?? "api.github.com"
        return baseURL
            .appending(path: host)
            .appending(path: owner)
            .appending(path: "\(name).json")
    }

    private static func defaultBaseURL(fileManager: FileManager) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "RepoBar"
        return support
            .appending(path: bundleID)
            .appending(path: "RepoDetailCache")
    }
}
