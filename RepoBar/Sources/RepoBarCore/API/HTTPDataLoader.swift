import Foundation

struct HTTPDataLoader {
    static let live = HTTPDataLoader { request in
        try await URLSession.shared.data(for: request)
    }

    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.load = load
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.load(request)
    }
}
