import Foundation
import AssignmentPipeline
import BrightspaceSession
import CoursePipeline

/// The real quiz source: cookie + CSRF token → JWT → `quizzes/` → `[Assignment]`.
///
/// Conforms to `AssignmentSource`, not to some new quiz protocol, which is what lets
/// `CompositeAssignmentSource` merge it with the dropbox source below the store. From
/// `AssignmentFetcher`'s side nothing about this is new.
///
/// Structurally a sibling of `BrightspaceCourseSource` and `BrightspaceAssignmentSource`,
/// on purpose — same three steps, same seam, same taxonomy — so the three network
/// adapters can be read and audited as one shape:
///
///   - `decodeMint(status:body:)` and `decodeAPI(status:)` are pure functions on plain
///     values. They own the failure classification; the network methods just execute a
///     request and hand the raw `(status, bytes)` over. That is what makes the taxonomy
///     inspectable without a socket.
///   - `fetchAssignments` is the impureim sandwich: effect (session) → effect (mint) →
///     effect (GET) → pure (`QuizParser.parse`).
///
/// SEAM: credentials come from a `SessionProviding`, asked **per fetch** — never held.
/// A session refreshed on disk (or, later, re-minted by a login window) is picked up on
/// the next fetch without restarting anything. The same provider instance serves the
/// course, assignment and quiz sources, so a refreshed cookie reaches all three.
///
/// Secrets discipline: the cookie, the CSRF token, and the JWT never touch a log, a
/// print, an error message, or the disk. Errors carry status codes and generic reasons
/// only.
///
/// One measured constraint worth knowing: experiment 6 proved that once a course's
/// `Access` window closes, every content route answers **403**. That is the expected
/// steady state for last term's courses, and it arrives here as `.httpStatus(403)` —
/// which, crucially, the composite treats as a partial failure rather than letting it
/// discard the course's assignments.
public struct BrightspaceQuizSource: AssignmentSource {

    private let provider: any SessionProviding
    private let session: URLSession

    private static let requestTimeout: TimeInterval = 30
    private static let mintPath = "/d2l/lp/auth/oauth2/token"

    public init(provider: any SessionProviding) {
        self.provider = provider

        // Ephemeral so nothing — cookies, response cache — is ever persisted to disk.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Shell: the three-step chain

    public func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        let credentials = try await self.resolveSession()                       // effect
        let jwt = try await self.mintJWT(credentials)                           // effect
        let body = try await self.getQuizzes(courseId: courseId, jwt: jwt, credentials) // effect
        return try QuizParser.parse(body, courseId: courseId)                   // pure
    }

    /// Step 0: ask the seam for credentials. A provider failure is a fetch failure like
    /// any other — mapped into the `CourseSourceError` taxonomy so the store answers it
    /// with `.preservedStale` and the submenu keeps what it had.
    private func resolveSession() async throws -> BrightspaceSession {
        do {
            return try await self.provider.session()
        } catch let error as SessionError {
            switch error {
            case .unavailable(let reason): throw CourseSourceError.transport(reason)
            case .malformed(let reason): throw CourseSourceError.malformedBody(reason)
            }
        } catch {
            throw CourseSourceError.transport(String(describing: error))
        }
    }

    /// Step 1: cookie-authenticated token mint. `POST /d2l/lp/auth/oauth2/token`.
    private func mintJWT(_ credentials: BrightspaceSession) async throws -> String {
        var request = URLRequest(url: try self.url(Self.mintPath, base: credentials.baseUrl))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue(credentials.cookieHeader, forHTTPHeaderField: "cookie")
        if let csrf = credentials.csrfToken {
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.httpBody = Data("scope=*:*:*".utf8)

        let (data, http) = try await self.perform(request)
        switch Self.decodeMint(status: http.statusCode, body: data) {
        case .token(let jwt): return jwt
        case .sessionExpired: throw CourseSourceError.sessionExpired
        case .failure(let error): throw error
        }
    }

    /// Step 2: bearer-authenticated GET of one course's quizzes.
    ///
    /// The route that was missing: the app fetched `dropbox/folders` only, so on the
    /// live tenant it showed 4 assignments while hiding 4 quizzes.
    private func getQuizzes(
        courseId: Int,
        jwt: String,
        _ credentials: BrightspaceSession
    ) async throws -> Data {
        let path = "/d2l/api/le/\(Self.leVersion)/\(courseId)/quizzes/"
        var request = URLRequest(url: try self.url(path, base: credentials.baseUrl))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await self.perform(request)
        if let error = Self.decodeAPI(status: http.statusCode) { throw error }
        return data
    }

    /// Confirmed against this tenant's own `GET /d2l/api/versions/`.
    private static let leVersion = "1.96"

    // MARK: - Doing: the single network primitive

    /// The only place a socket is touched. Anything that stops a request from returning
    /// an HTTP response — offline, DNS, timeout, TLS — becomes `.transport`. Typed
    /// errors thrown downstream are passed through untouched.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CourseSourceError.transport("response was not HTTP")
            }
            return (data, http)
        } catch let error as CourseSourceError {
            throw error
        } catch {
            throw CourseSourceError.transport(String(describing: error))
        }
    }

    private func url(_ path: String, base: String) throws -> URL {
        guard let url = URL(string: base + path) else {
            throw CourseSourceError.transport("malformed request URL")
        }
        return url
    }

    // MARK: - Deciding: pure failure taxonomy (no I/O, no secrets)

    private enum MintDecision {
        case token(String)
        case sessionExpired
        case failure(CourseSourceError)
    }

    /// Classify a mint response. Measured, not guessed: a dead session comes back at
    /// **HTTP 200** carrying an HTML stub whose script redirects to
    /// `/d2l/login?sessionExpired=1`. There is no 401 on this path, so the marker — not
    /// the status — is the only honest signal, and it is checked first.
    private static func decodeMint(status: Int, body: Data) -> MintDecision {
        if String(decoding: body, as: UTF8.self).contains("sessionExpired=1") {
            return .sessionExpired
        }
        guard (200..<300).contains(status) else {
            return .failure(.httpStatus(status))
        }
        guard
            let token = (try? JSONDecoder().decode(TokenResponse.self, from: body))?.accessToken,
            !token.isEmpty
        else {
            return .failure(.malformedBody("token mint returned no access_token"))
        }
        return .token(token)
    }

    /// The bearer API answers honestly: 2xx is success, anything else is its real
    /// status. 403 is the one to expect — it is what an ended course returns. The body
    /// is left to the parser.
    private static func decodeAPI(status: Int) -> CourseSourceError? {
        (200..<300).contains(status) ? nil : .httpStatus(status)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
}
