import Foundation
@testable import RepoBarCore
import Testing

struct ActionsUsageInfoTests {
    @Test
    func `current month minutes include GitHub billing date only rows`() {
        let usage = ActionsUsageInfo(
            items: [
                Self.item(date: "2026-05-01", quantity: 12),
                Self.item(date: "2026-05-14T10:15:00Z", quantity: 3),
                Self.item(date: "2026-04-30", quantity: 100),
                Self.item(date: "2026-05-02", quantity: 7, unitType: "gb")
            ],
            fetchedAt: Self.date("2026-05-14T12:00:00Z")
        )

        #expect(usage.minutesUsedInCurrentMonth(now: Self.date("2026-05-14T12:00:00Z")) == 15)
    }

    @Test
    func `current month minutes bucket date only rows in UTC`() throws {
        let previousTimeZone = NSTimeZone.default
        NSTimeZone.default = try #require(TimeZone(secondsFromGMT: -8))
        defer { NSTimeZone.default = previousTimeZone }

        let usage = ActionsUsageInfo(
            items: [Self.item(date: "2026-05-01", quantity: 12)],
            fetchedAt: Self.date("2026-05-01T12:00:00Z")
        )

        #expect(usage.minutesUsedInCurrentMonth(now: Self.date("2026-05-01T12:00:00Z")) == 12)
    }

    @Test
    func `usage date parser accepts date only and internet dates`() {
        #expect(ActionsUsageInfo.date(fromUsageDate: "2026-05-01") == Self.date("2026-05-01T00:00:00Z"))
        #expect(ActionsUsageInfo.date(fromUsageDate: "2026-05-01T12:34:56Z") == Self.date("2026-05-01T12:34:56Z"))
        #expect(ActionsUsageInfo.date(fromUsageDate: "not-a-date") == nil)
    }

    @Test
    func `remaining concurrent jobs ignores queued runs`() {
        let status = ActionsQueueStatus(
            inProgressCount: 2,
            queuedCount: 30,
            fetchedAt: Self.date("2026-05-14T12:00:00Z"),
            scannedRepositoryCount: 5,
            totalRepositoryCount: 12
        )

        #expect(status.totalActiveCount == 32)
        #expect(status.remainingConcurrentJobs(limit: 20) == 18)
        #expect(status.remainingConcurrentPercent(limit: 20) == 90)
        #expect(status.repositorySampleDescription == "Sampled 5 of 12 repos")
    }

    @Test
    func `repository sample description stays hidden for exhaustive queue scans`() {
        let status = ActionsQueueStatus(
            inProgressCount: 0,
            queuedCount: 0,
            fetchedAt: Self.date("2026-05-14T12:00:00Z"),
            scannedRepositoryCount: 4,
            totalRepositoryCount: 4
        )

        #expect(status.isRepositorySampled == false)
        #expect(status.repositorySampleDescription == nil)
    }

    @Test
    func `repository sample description appears even when sampled jobs are idle`() {
        let status = ActionsQueueStatus(
            inProgressCount: 0,
            queuedCount: 0,
            fetchedAt: Self.date("2026-05-14T12:00:00Z"),
            scannedRepositoryCount: 5,
            totalRepositoryCount: 9
        )

        #expect(status.totalActiveCount == 0)
        #expect(status.isRepositorySampled)
        #expect(status.repositorySampleDescription == "Sampled 5 of 9 repos")
    }

    @Test
    func `runner repository sample description appears for sampled personal repos`() {
        let runners = ActionsRunnerInfo(
            totalCount: 0,
            runners: [],
            fetchedAt: Self.date("2026-05-14T12:00:00Z"),
            scannedRepositoryCount: 5,
            totalRepositoryCount: 8
        )

        #expect(runners.isRepositorySampled)
        #expect(runners.repositorySampleDescription == "Sampled 5 of 8 repos")
    }

    private static func item(date: String, quantity: Double, unitType: String = "minutes") -> ActionsUsageItem {
        ActionsUsageItem(
            date: date,
            product: "actions",
            sku: "Actions Linux",
            quantity: quantity,
            unitType: unitType,
            pricePerUnit: 0,
            grossAmount: 0,
            netAmount: 0,
            organizationName: nil,
            repositoryName: nil
        )
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }
}
