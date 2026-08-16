import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// Announcements, end to end through the adapter: a course fetch lands, the
// announcement fan-out runs, and `currentMenu()` serves a submenu whose
// announcements section came from the store — the full production wiring with
// only the sources faked.
//
// PRIORITY: THE JOIN, not the rules. Every translation rule (cutoff, cap,
// order, silence on failure) is pinned in `AnnouncementTranslationTests`; every
// store/fetcher rule in `AnnouncementPipeline`'s own suites. What none of them
// can catch is a feed wired to the wrong store, a fan-out that never runs, or
// states read for the wrong course — the silent failures this file exists for.
//
// SCOPE: Google-medium by the adapter's own standard (actor hops, a scratch
// cache file), same as `EndToEndTests`.
// ═════════════════════════════════════════════════════════════════════════════

/// One course's announcements, scripted per course id. Courses without a script
/// throw, mirroring the daemon's "absent means unknown" contract.
private struct ScriptedAnnouncementSource: AnnouncementSource {
    let byCourse: [Int: [Announcement]]

    func fetchAnnouncements(courseId: Int) async throws -> [Announcement] {
        guard let items = self.byCourse[courseId] else {
            throw CourseSourceError.transport("course \(courseId) is not in the daemon cache")
        }
        return items
    }
}

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

@Suite("Announcements — the adapter join, end to end")
struct AnnouncementEndToEndTests {

    @Test("a refresh lands announcements inside the fetched course's submenu")
    func refreshLandsAnnouncementsInTheSubmenu() async throws {
        // Arrange — one visible (undated) course, one announcement posted
        // yesterday, the whole stack real except the two sources.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let course = Course(
            id: 412_690, name: "Purdue Civics Knowledge Test", code: "wl.nc.civics.test",
            role: "Learner", isActive: true, homeUrl: nil
        )
        let courseSource = CountingSource([.courses([course])])
        let cache = CourseCache(fileURL: scratch.file(), clock: clock, staleAfter: 3600)
        let poller = Poller(
            source: courseSource, cache: cache,
            policy: PollPolicy(interval: 3600), clock: clock
        )
        let posted = epoch.addingTimeInterval(-86_400)
        let announcements = AnnouncementFeed(
            source: ScriptedAnnouncementSource(byCourse: [
                412_690: [Announcement(id: 9_001, courseId: 412_690, title: "Room change", date: posted)]
            ]),
            clock: clock
        )
        let adapter = MenuAdapter(
            poller: poller, cache: cache, baseURL: RealData.baseURL, clock: clock,
            announcements: announcements
        )

        // Act — the GUI's Refresh click, verbatim.
        let model = await adapter.refresh()

        // Assert — the section, inside the right course's submenu, with the
        // uniform course-news URL.
        let row = try #require(model.courses.first { $0.id == 412_690 })
        let announcementRows = row.submenu.compactMap {
            if case .announcement(let announcement) = $0 { announcement } else { nil }
        }
        try #require(announcementRows.count == 1)
        #expect(announcementRows[0].title == "Room change")
        #expect(announcementRows[0].url == AnnouncementLink.url(courseId: 412_690, baseURL: RealData.baseURL))
        #expect(row.submenu.contains(.sectionHeader("Announcements")))
    }

    @Test("without a feed the menu is exactly the pre-announcement menu")
    func nilFeedChangesNothing() async throws {
        // Arrange — two adapters over identical data; only the feed differs.
        // This is the compatibility claim every pre-announcement call site
        // relies on, proven at the top of the stack rather than assumed.
        let scratch = try ScratchDir()
        let clock = ManualClock(epoch)
        let course = Course(
            id: 412_690, name: "Purdue Civics Knowledge Test", code: "wl.nc.civics.test",
            role: "Learner", isActive: true, homeUrl: nil
        )

        func build(feed: AnnouncementFeed?) async -> MenuModel {
            let cache = CourseCache(fileURL: scratch.file(), clock: clock, staleAfter: 3600)
            let poller = Poller(
                source: CountingSource([.courses([course])]), cache: cache,
                policy: PollPolicy(interval: 3600), clock: clock
            )
            let adapter = MenuAdapter(
                poller: poller, cache: cache, baseURL: RealData.baseURL, clock: clock,
                announcements: feed
            )
            return await adapter.refresh()
        }

        // Act — a feed whose fetch always fails with nothing known contributes
        // no rows, and no feed contributes no rows; both must equal each other.
        let without = await build(feed: nil)
        let withEmptyFeed = await build(
            feed: AnnouncementFeed(source: ScriptedAnnouncementSource(byCourse: [:]), clock: clock)
        )

        // Assert
        #expect(without == withEmptyFeed)
    }
}
