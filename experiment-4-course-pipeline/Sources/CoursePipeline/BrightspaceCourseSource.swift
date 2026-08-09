import Foundation

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
/// Secrets discipline: the cookie, the CSRF token, and the JWT never touch a log, a print,
/// an error message, or the disk. Errors carry status codes and generic reasons only.
public struct BrightspaceCourseSource: CourseSource {

    private let baseURL: String
    private let cookieHeader: String
    private let csrfToken: String?
    private let session: URLSession

    private static let requestTimeout: TimeInterval = 30
    private static let mintPath = "/d2l/lp/auth/oauth2/token"
    private static let enrollmentsPath =
        "/d2l/api/lp/1.62/enrollments/myenrollments/?orgUnitTypeId=3&isActive=true"

    /// Explicit construction — pure, no I/O. Kept separate from `loadSession` so the
    /// value and the act of reading it off disk stay independently exercisable.
    public init(baseURL: String, cookieHeader: String, csrfToken: String?) {
        self.baseURL = baseURL
        self.cookieHeader = cookieHeader
        self.csrfToken = csrfToken

        // Ephemeral so nothing — cookies, response cache — is ever persisted to disk.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    /// The wiring the contract test uses: read the captured session, then construct.
    public init() throws {
        let session = try Self.loadSession()
        self.init(
            baseURL: session.baseUrl,
            cookieHeader: session.cookieHeader,
            csrfToken: session.csrfToken
        )
    }

    // MARK: - Shell: the three-step chain

    public func fetchCourses() async throws -> [Course] {
        let jwt = try await self.mintJWT()                  // effect
        let body = try await self.getEnrollments(jwt: jwt)  // effect
        return try EnrollmentParser().parse(body)           // pure — reused taxonomy
    }

    /// Step 1: cookie-authenticated token mint. `POST /d2l/lp/auth/oauth2/token`.
    private func mintJWT() async throws -> String {
        var request = URLRequest(url: try self.url(Self.mintPath))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue(self.cookieHeader, forHTTPHeaderField: "cookie")
        if let csrf = self.csrfToken {
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
    private func getEnrollments(jwt: String) async throws -> Data {
        var request = URLRequest(url: try self.url(Self.enrollmentsPath))
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

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: self.baseURL + path) else {
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

    // MARK: - Doing: session file at the edge

    private struct Session: Decodable {
        let baseUrl: String
        let cookieHeader: String
        let csrfToken: String?
    }

    /// Read the captured session from `SESSION_JSON` (default
    /// `../experiment-1-fresh-cookie/artifacts/session.json`), resolved against the
    /// package root — not the CWD — so it works whatever directory `swift test` runs in.
    /// Never copied here, never logged: only field values reach memory.
    private static func loadSession() throws -> Session {
        let url = self.sessionFileURL()
        guard let data = try? Data(contentsOf: url) else {
            throw CourseSourceError.transport("session file unavailable at \(url.lastPathComponent)")
        }
        guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
            throw CourseSourceError.malformedBody("session file was not the expected shape")
        }
        return session
    }

    private static func sessionFileURL() -> URL {
        let raw = ProcessInfo.processInfo.environment["SESSION_JSON"]
            ?? "../experiment-1-fresh-cookie/artifacts/session.json"
        // An absolute SESSION_JSON ignores the base; a relative one resolves against root.
        return URL(fileURLWithPath: raw, relativeTo: self.packageRoot()).standardizedFileURL
    }

    /// `#filePath` is `<root>/Sources/CoursePipeline/BrightspaceCourseSource.swift`; three
    /// parents up is the package root, independent of the working directory.
    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Sources/CoursePipeline
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // <root>
            .standardizedFileURL
    }
}
