import Foundation
import RepoBarCore
import Testing

struct HeatmapSpanCoverageTests {
    @Test
    func `labels cover all cases`() {
        #expect(HeatmapSpan.oneMonth.label == "1 month")
        #expect(HeatmapSpan.threeMonths.label == "3 months")
        #expect(HeatmapSpan.sixMonths.label == "6 months")
        #expect(HeatmapSpan.twelveMonths.label == "12 months")
        #expect(HeatmapSpan.twelveMonths.months == 12)
    }

    @Test
    func `range align to week false uses direct month offset`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let range = HeatmapFilter.range(span: .oneMonth, now: now, calendar: calendar, alignToWeek: false)
        #expect(range.end == calendar.startOfDay(for: now))
        #expect(range.start < range.end)

        let aligned = HeatmapFilter.range(span: .oneMonth, now: now, calendar: calendar, alignToWeek: true)
        #expect(aligned.start < aligned.end)
    }

    @Test
    func `filter helpers cover overloads`() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let cells = [
            HeatmapCell(date: now.addingTimeInterval(-86400 * 10), count: 1),
            HeatmapCell(date: now.addingTimeInterval(-86400 * 100), count: 1)
        ]
        let filtered = HeatmapFilter.filter(cells, span: .oneMonth, now: now)
        #expect(filtered.count == 1)

        let filteredAligned = HeatmapFilter.filter(cells, span: .oneMonth, now: now, alignToWeek: true)
        #expect(filteredAligned.count == 1)

        let filteredUnaligned = HeatmapFilter.filter(cells, span: .oneMonth, now: now, alignToWeek: false)
        #expect(filteredUnaligned.count == 1)

        let range = HeatmapFilter.alignedRange(span: .oneMonth, now: now)
        #expect(range.start < range.end)

        let explicit = HeatmapRange(start: now.addingTimeInterval(-86400 * 20), end: now)
        #expect(HeatmapFilter.filter(cells, range: explicit).count == 1)
    }
}
