import Foundation
@preconcurrency import GRDB

struct PersistentGraphQLResponse: Equatable {
    let data: Data
    let fetchedAt: Date
}

final class GraphQLResponseDiskCache {
    private let queue: DatabaseQueue
    private let clock: @Sendable () -> Date
    private let logger = RepoBarLogging.logger("graphql-cache-db")

    init(path: String, clock: @escaping @Sendable () -> Date = Date.init) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        self.queue = try DatabaseQueue(path: path, configuration: configuration)
        self.clock = clock
        try HTTPResponseDiskCache.migrate(self.queue)
    }

    static func standard() -> GraphQLResponseDiskCache? {
        self.scoped(accountID: nil)
    }

    /// Account-scoped GraphQL cache. Falls back to the shared `standard()`
    /// database when `accountID` is nil so legacy callers keep working.
    static func scoped(accountID: String?) -> GraphQLResponseDiskCache? {
        let url = HTTPResponseDiskCache.databaseURL(accountID: accountID)
            ?? HTTPResponseDiskCache.standardDatabaseURL()
        guard let path = url?.path else { return nil }

        do {
            return try GraphQLResponseDiskCache(path: path)
        } catch {
            RepoBarLogging.logger("graphql-cache-db").error("Unable to open persistent GraphQL cache: \(error.localizedDescription)")
            return nil
        }
    }

    func cached(key: String, maxAge: TimeInterval, now: Date = Date()) -> PersistentGraphQLResponse? {
        guard let response = self.response(key: key) else { return nil }

        if now.timeIntervalSince(response.fetchedAt) <= maxAge {
            return response
        }
        return nil
    }

    func stale(key: String) -> PersistentGraphQLResponse? {
        self.response(key: key)
    }

    func save(key: String, endpoint: URL, operation: String, body: Data, responseBody: Data) {
        let now = self.clock()
        do {
            try self.queue.write { db in
                try db.execute(
                    sql: """
                    insert into graphql_responses(
                        key, endpoint, operation, body_hash, response_body, fetched_at, updated_at
                    )
                    values (?, ?, ?, ?, ?, ?, ?)
                    on conflict(key) do update set
                        endpoint = excluded.endpoint,
                        operation = excluded.operation,
                        body_hash = excluded.body_hash,
                        response_body = excluded.response_body,
                        fetched_at = excluded.fetched_at,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        key,
                        endpoint.absoluteString,
                        operation,
                        Self.bodyHash(body),
                        responseBody,
                        now.timeIntervalSinceReferenceDate,
                        now.timeIntervalSinceReferenceDate
                    ]
                )
            }
        } catch {
            self.logger.error("Unable to save GraphQL response: \(error.localizedDescription)")
        }
    }

    private func response(key: String) -> PersistentGraphQLResponse? {
        do {
            return try self.queue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "select response_body, fetched_at from graphql_responses where key = ?",
                    arguments: [key]
                ) else { return nil }

                let body: Data = row["response_body"]
                let fetchedAt: Double = row["fetched_at"]
                return PersistentGraphQLResponse(
                    data: body,
                    fetchedAt: Date(timeIntervalSinceReferenceDate: fetchedAt)
                )
            }
        } catch {
            self.logger.error("Unable to read GraphQL response: \(error.localizedDescription)")
            return nil
        }
    }

    private static func bodyHash(_ data: Data) -> String {
        data.base64EncodedString()
    }
}
