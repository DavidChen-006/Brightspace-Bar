import Foundation
@testable import RepoBarCore
import Testing

struct GraphQLContributionParsingTests {
    @Test
    func `parses contribution day date only`() throws {
        let data = Data(#"{"date":"2025-12-28","contributionCount":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ContributionDay.self, from: data)
        #expect(decoded.contributionCount == 3)

        let calendar = Calendar(identifier: .gregorian)
        let components = try calendar.dateComponents(in: #require(TimeZone(secondsFromGMT: 0)), from: decoded.date)
        #expect(components.year == 2025)
        #expect(components.month == 12)
        #expect(components.day == 28)
    }

    @Test
    func `parses contribution day date time with fractional seconds`() throws {
        let data = Data(#"{"date":"2025-12-28T12:34:56.123Z","contributionCount":1}"#.utf8)
        let decoded = try JSONDecoder().decode(ContributionDay.self, from: data)
        #expect(decoded.contributionCount == 1)

        let calendar = Calendar(identifier: .gregorian)
        let components = try calendar.dateComponents(in: #require(TimeZone(secondsFromGMT: 0)), from: decoded.date)
        #expect(components.year == 2025)
        #expect(components.month == 12)
        #expect(components.day == 28)
        #expect(components.hour == 12)
        #expect(components.minute == 34)
        #expect(components.second == 56)
    }
}
