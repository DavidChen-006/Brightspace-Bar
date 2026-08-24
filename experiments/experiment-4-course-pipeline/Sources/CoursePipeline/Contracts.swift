import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// CONTRACT FILE — owned by the orchestrator.
//
// These are the seams the three modules (parsing / caching / polling) meet at.
// Agents MUST NOT change the declarations in this file: three concerns are being
// built in parallel against them, and a unilateral edit here breaks the others.
//
// Everything NOT in this file — the parser, the cache, the poller, the fakes,
// the real Brightspace adapter — is yours to design.
//
// This file deliberately contains data and protocols only. No logic lives here.
// ─────────────────────────────────────────────────────────────────────────────

/// One enrolled course, already parsed out of D2L's `myenrollments` payload.
///
/// `startDate` / `endDate` stay as the raw ISO-8601 strings D2L sends (or nil).
/// v1 renders a list of names and never filters by term, so date *parsing* is a
/// separate concern that can be added later without breaking this contract.
public struct Course: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let code: String
    public let role: String
    public let isActive: Bool
    /// `OrgUnit.HomeUrl`, preserved verbatim — **usually `null`**.
    ///
    /// Measured: non-null in only 2 of 27 items, both non-semester shell courses; every
    /// real class sends `null`. So this field cannot drive the click action. Derive that
    /// from `id` instead (`{baseUrl}/d2l/home/{id}` — both non-null samples match that
    /// shape exactly, and `ImageUrl` is non-null 27/27 embedding the same `id`).
    ///
    /// Kept in the model anyway because the contract here is faithful preservation:
    /// synthesizing a URL is a UI policy decision and belongs at the click layer.
    public let homeUrl: String?
    public let startDate: String?
    public let endDate: String?

    public init(
        id: Int,
        name: String,
        code: String,
        role: String,
        isActive: Bool,
        homeUrl: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.code = code
        self.role = role
        self.isActive = isActive
        self.homeUrl = homeUrl
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// Why a fetch failed.
///
/// `sessionExpired` is the one that matters most, and it is **narrower than you
/// might assume** — measured against the live tenant, not guessed:
///
/// - The **cookie-authenticated token mint** (`POST /d2l/lp/auth/oauth2/token`)
///   answers a dead session with **HTTP 200** and a 294-byte HTML stub whose
///   script redirects to `/d2l/login?sessionExpired=1&…`. There is no 401.
///   Code keying on `status == 200` alone reads that as success, decodes zero
///   courses, and overwrites a good cache with an empty list.
/// - The **bearer-authenticated API** behaves correctly: a bad or unparseable
///   JWT yields a real `401` with an RFC 7807 `problem+json` body
///   (`{"title":"Unauthorized","status":401,"detail":"Couldn't parse token"}`).
///
/// So the stub guard belongs on the mint path; API calls get honest statuses.
/// Both fixtures are checked in under `Tests/CoursePipelineTests/Fixtures/`.
public enum CourseSourceError: Error, Equatable, Sendable {
    /// HTTP 200 plus the `sessionExpired=1` login stub. Mint path.
    case sessionExpired
    /// A genuinely non-2xx status.
    case httpStatus(Int)
    /// 2xx, but the body was not a decodable enrollment payload.
    case malformedBody(String)
    /// Never reached the server (offline, DNS, timeout, TLS).
    case transport(String)
}

/// Anything that can produce the current course list.
///
/// Two implementations exist by design: a scriptable fake used by every test,
/// and the real Brightspace adapter. This is the swap point.
public protocol CourseSource: Sendable {
    func fetchCourses() async throws -> [Course]
}

/// Injected time. Staleness must be testable without sleeping, so nothing in
/// this package may call `Date()` directly — take a `Clock` instead.
public protocol Clock: Sendable {
    var now: Date { get }
}

/// What happened when a fetch result was folded into the cache.
///
/// The three cases carry the whole point of the cache, so they are part of the
/// contract rather than an implementation detail:
///
/// - `unchanged`: fetch succeeded and matched what we already had. Do not
///   rewrite the file, do not rebuild the menu.
/// - `updated`: fetch succeeded and differed. Replace, persist, rebuild.
/// - `preservedStale`: fetch failed. Keep serving the old list. **Never** clobber
///   good data with an empty list because auth died.
public enum CacheOutcome: Equatable, Sendable {
    case unchanged
    case updated
    case preservedStale(CourseSourceError)
}

/// What caused a poll attempt. Different triggers get different staleness rules
/// (a manual refresh should always fetch; a menu-open should not refetch data
/// that is five minutes old).
public enum PollTrigger: Equatable, Sendable, CaseIterable {
    case launch
    case menuOpened
    case timer
    case manual
}
