import Foundation

public struct RateLimitDisplayState: Sendable {
    public let diagnostics: DiagnosticsSummary
    public let cacheSummary: RepoBarCacheSummary?
    public let authMethod: AuthMethod?

    public init(
        diagnostics: DiagnosticsSummary,
        cacheSummary: RepoBarCacheSummary? = nil,
        authMethod: AuthMethod? = nil
    ) {
        self.diagnostics = diagnostics
        self.cacheSummary = cacheSummary
        self.authMethod = authMethod
    }

    public var juice: RateLimitJuice {
        RateLimitJuice(
            diagnostics: self.diagnostics,
            cacheSummary: self.cacheSummary
        )
    }

    public var lastUpdatedAt: Date? {
        [
            self.diagnostics.rateLimitResources?.fetchedAt,
            self.diagnostics.restRateLimit?.fetchedAt,
            self.diagnostics.graphQLRateLimit?.fetchedAt,
            self.cacheSummary?.latestResponses.map(\.fetchedAt).max()
        ]
        .compactMap(\.self)
        .max()
    }

    public func compactSummary(now: Date = Date()) -> String {
        RateLimitStatusFormatter.compactSummary(
            diagnostics: self.diagnostics,
            cacheSummary: self.cacheSummary,
            authMethod: self.authMethod,
            now: now
        )
    }

    public func sections(now: Date = Date()) -> [RateLimitDisplaySection] {
        RateLimitStatusFormatter.sections(
            diagnostics: self.diagnostics,
            cacheSummary: self.cacheSummary,
            authMethod: self.authMethod,
            now: now
        )
    }

    public func isLimited(now: Date = Date()) -> Bool {
        if self.diagnostics.rateLimitReset.map({ $0 > now }) ?? false {
            return true
        }
        if self.diagnostics.endpointCooldowns.contains(where: { $0.retryAfter > now }) {
            return true
        }
        return self.cacheSummary?.rateLimits.contains { $0.resetAt > now } ?? false
    }
}
