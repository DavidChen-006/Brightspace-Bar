import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SEAM: session acquisition.
//
// Everything downstream (the token mint, the enrollments GET) needs exactly three
// strings, and none of it cares where they came from. This module owns that
// boundary so the answer can change without touching the pipeline:
//
//   today  — `FileSessionProvider`: a JSON file that `Scripts/refresh-session.sh`
//            fills from a browser capture
//   later  — a `WKWebView` login window: user signs in with MFA, cookies are read
//            from `WKHTTPCookieStore`, no file involved
//
// Swapping the two is a one-line change in `main.swift` and nothing else.
//
// Secrets discipline: `cookieHeader` and `csrfToken` are credentials. They must
// never appear in a log, a print, an error message, or an error's associated
// values — `SessionError` reasons carry file names and shapes only.
// ─────────────────────────────────────────────────────────────────────────────

/// The three values a Brightspace request chain needs. A plain value: how they
/// were obtained is the provider's business.
public struct BrightspaceSession: Sendable, Equatable {
    public let baseUrl: String
    public let cookieHeader: String
    public let csrfToken: String?

    public init(baseUrl: String, cookieHeader: String, csrfToken: String?) {
        self.baseUrl = baseUrl
        self.cookieHeader = cookieHeader
        self.csrfToken = csrfToken
    }
}

/// Why a provider could not produce a session. Reasons are for humans and logs,
/// so by contract they never contain a credential.
public enum SessionError: Error, Equatable {
    /// The provider's backing store has nothing — no file, no login, no capture.
    case unavailable(String)
    /// The backing store had bytes, but not the expected shape.
    case malformed(String)
}

/// The seam. `session()` is async and throwing so that every future provider —
/// a file read, a keychain lookup, an interactive login — fits without changing
/// the signature.
public protocol SessionProviding: Sendable {
    func session() async throws -> BrightspaceSession
}

/// A provider that always returns one fixed session. The degenerate case, for
/// tests and for wiring a source directly from known values.
public struct StaticSessionProvider: SessionProviding {
    private let value: BrightspaceSession

    public init(_ value: BrightspaceSession) {
        self.value = value
    }

    public func session() async throws -> BrightspaceSession {
        self.value
    }
}
