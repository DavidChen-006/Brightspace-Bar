import Foundation
import BrightspaceSession

/// The real `CourseSource`: cookie + CSRF token → JWT → `myenrollments` → `[Course]`.
///
/// A direct port of `experiment-2-cookie-to-jwt/src/mint-and-call.mjs`, proven live.
/// The module is almost entirely imperative shell — three network steps — so the design
/// work is keeping the *decisions* out of the *doing*:
///
///   - `decodeMint(status:body:)` and `decodeAPI(status:)` are pure functions on plain
///     values. They own the failure taxonomy; the network methods just execute a request
///     and hand the raw `(status, bytes)` to them. That is what makes the classification
///     inspectable without a socket.
///   - `fetchCourses()` is the impureim sandwich: effect (mint) → effect (GET) → pure
///     (`EnrollmentParser.parse`). Parsing — including its own stub/malformed taxonomy —
///     is reused verbatim, never reimplemented here.
///
/// SEAM: credentials come from a `SessionProviding`, asked **per fetch** — never held.
/// So a session refreshed on disk (or, later, re-minted by a login window) is picked up
/// on the next poll without restarting anything.
///
/// Secrets discipline: the cookie, the CSRF token, and the JWT never touch a log, a print,
/// an error message, or the disk. Errors carry status codes and generic reasons only.
public struct BrightspaceCourseSource: CourseSource {

    private let provider: any SessionProviding
    private let session: URLSession

    private static let requestTimeout: TimeInterval = 30
    private static let mintPath = "/d2l/lp/auth/oauth2/token"
    private static let enrollmentsPath =
        "/d2l/api/lp/1.62/enrollments/myenrollments/?orgUnitTypeId=3&isActive=true"

    public init(provider: any SessionProviding) {
        self.provider = provider

        // Ephemeral so nothing — cookies, response cache — is ever persisted to disk.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    /// Construction from known values — tests, or wiring without a file.
    public init(baseURL: String, cookieHeader: String, csrfToken: String?) {
        self.init(provider: StaticSessionProvider(BrightspaceSession(
            baseUrl: baseURL,
            cookieHeader: cookieHeader,
            csrfToken: csrfToken
        )))
    }

    // MARK: - Shell: the three-step chain

    public func fetchCourses() async throws -> [Course] {
        let credentials = try await self.resolveSession()               // effect
        let jwt = try await self.mintJWT(credentials)                   // effect
        let body = try await self.getEnrollments(jwt: jwt, credentials) // effect
        return try EnrollmentParser().parse(body)                       // pure — reused taxonomy
    }

    /// Step 0: ask the seam for credentials. A provider failure is a fetch failure
    /// like any other — mapped into the `CourseSourceError` taxonomy so the cache
    /// answers it with `.preservedStale` and the menu keeps its courses.
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

    /// Step 2: bearer-authenticated GET of the enrollment list.
    private func getEnrollments(jwt: String, _ credentials: BrightspaceSession) async throws -> Data {
        var request = URLRequest(url: try self.url(Self.enrollmentsPath, base: credentials.baseUrl))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, http) = try await self.perform(request)
        if let error = Self.decodeAPI(status: http.statusCode) { throw error }
        return data
    }

    // MARK: - Doing: the single network primitive

    /// The only place a socket is touched. Anything that stops a request from returning an
    /// HTTP response — offline, DNS, timeout, TLS — becomes `.transport`. Typed errors
    /// thrown downstream of the response are passed through untouched.
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
    /// **HTTP 200** carrying a 294-byte HTML stub whose script redirects to
    /// `/d2l/login?sessionExpired=1`. There is no 401 on this path, so the marker — not
    /// the status — is the only honest signal, and it is checked first. A genuine non-2xx
    /// maps to `.httpStatus`; a 200 with no `access_token` is a shape we did not expect.
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

    /// The bearer API answers honestly: 2xx is success, anything else is its real status
    /// (a bad JWT is a true 401 + `problem+json`). The body is left to the parser.
    private static func decodeAPI(status: Int) -> CourseSourceError? {
        (200..<300).contains(status) ? nil : .httpStatus(status)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
}
