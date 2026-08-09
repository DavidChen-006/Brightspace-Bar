import Foundation

/// The session provider the app ships with today: a JSON file captured by a real
/// browser login and placed at a well-known path by `Scripts/refresh-session.sh`.
///
/// The file is read **fresh on every call**, deliberately. Replacing it while the
/// app is running takes effect on the next fetch — no relaunch, which is exactly
/// what makes an external refresh script viable at all.
public struct FileSessionProvider: SessionProviding {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The production resolution: `SESSION_JSON` (absolute, or relative to the
    /// working directory) when set — which is how tests point at a fixture —
    /// otherwise `~/Library/Application Support/BrightspaceBar/session.json`.
    ///
    /// Deliberately NOT a path inside the repository: the app must keep working
    /// if the source tree moves, and no credential should ever live where a
    /// `git add` could reach it.
    public static var standard: FileSessionProvider {
        if let raw = ProcessInfo.processInfo.environment["SESSION_JSON"] {
            return FileSessionProvider(fileURL: URL(fileURLWithPath: raw).standardizedFileURL)
        }
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "BrightspaceBar")
            .appending(path: "session.json")
        return FileSessionProvider(fileURL: url)
    }

    /// The capture's shape — experiment 1 writes more fields (`capturedAt`,
    /// `cookies`, screenshots of the login); only these three matter here.
    private struct Stored: Decodable {
        let baseUrl: String
        let cookieHeader: String
        let csrfToken: String?
    }

    public func session() async throws -> BrightspaceSession {
        guard let data = try? Data(contentsOf: self.fileURL) else {
            // Last path component only: the reason may be logged, the full path
            // is nobody's business, and the content certainly is not.
            throw SessionError.unavailable("no session file at \(self.fileURL.lastPathComponent)")
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw SessionError.malformed("session file was not the expected shape")
        }
        return BrightspaceSession(
            baseUrl: stored.baseUrl,
            cookieHeader: stored.cookieHeader,
            csrfToken: stored.csrfToken
        )
    }
}
