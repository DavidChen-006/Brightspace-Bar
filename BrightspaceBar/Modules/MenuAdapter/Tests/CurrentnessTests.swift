import Foundation
import Testing

import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// Currentness — the menu shows what you are taking NOW, not what you ever took.
//
// PRIORITY: correctness of the currentness decision. It is a pure function of
// (Access dates, now) — `now` injected, so every boundary is testable without
// waiting for a semester to end. Measured facts this policy rests on:
//   - `IsActive` is true for ALL 27 real enrollments, including Fall 2024 —
//     useless as a "currently taking" signal.
//   - `Access.StartDate/EndDate` are populated on 25 of 27; the 2 undated are
//     administrative shells (Civics Test, Scholarly Project Milestones).
//   - One real course (STARS 2025) has a nil start and a real end.
//
// THE POLICY (user decision 2026-08-24, superseding 2026-08-09):
//   - current  = has at least one date, start ≤ now ≤ end (missing bound = unbounded)
//   - undated  = no parseable dates at all → HIDDEN. The undated administrative
//     shells (Civics Test, Scholarly Project Milestones) are not being taken;
//     real classes exist, so "Other" earns them no menu space and no fetches.
//   - unparseable dates degrade to undated → hidden: courses fail CLOSED if D2L
//     ever changes its wire format, and "No current courses" is the tell.
//   - everything else (ended, not yet started) → hidden
//   - no current courses but courses exist → an honest "No current courses" line
//
// SCOPE: small. Pure translation on plain values; the real fixture bytes give
// the two probe-date cases an independent source of truth.
// ═════════════════════════════════════════════════════════════════════════════

private let base = URL(string: "https://purdue.brightspace.com")!

/// Fixed "now": 2025-10-01T00:00:00Z — mid Fall 2025 semester.
private let midFall2025 = Date(timeIntervalSince1970: 1_759_276_800)

/// Course builder with explicit date strings in D2L's exact wire format.
private func course(
    id: Int,
    code: String = "wl.202610.CS.25100.LE1",
    start: String?,
    end: String?
) -> Course {
    Course(
        id: id, name: "Course \(id)", code: code, role: "Student", isActive: true,
        homeUrl: nil, startDate: start, endDate: end
    )
}

/// The `.course` ids actually rendered, in row order.
private func renderedIds(_ model: MenuModel) -> [Int] {
    model.rows.compactMap { if case .course(let r) = $0 { r.id } else { nil } }
}

private func headers(_ model: MenuModel) -> [String] {
    model.rows.compactMap { if case .sectionHeader(let t) = $0 { t } else { nil } }
}

private func messages(_ model: MenuModel) -> [String] {
    model.rows.compactMap { if case .message(let t) = $0 { t } else { nil } }
}

@Suite("Currentness — dated courses against the injected clock")
struct CurrentnessDecisionTests {

    @Test("a course whose window contains now is shown")
    func currentCourseIsShown() {
        // Arrange — window comfortably around midFall2025.
        let enrolled = [course(id: 1, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z")]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [1])
        #expect(messages(model).isEmpty)
    }

    @Test("an ended course is hidden")
    func endedCourseIsHidden() {
        // Arrange — Fall 2024's real window, long over by midFall2025.
        let enrolled = [
            course(id: 1, start: "2024-08-14T04:00:00.000Z", end: "2024-12-29T04:59:00.000Z"),
            course(id: 2, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z"),
        ]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [2])
    }

    @Test("a not-yet-started course is hidden")
    func futureCourseIsHidden() {
        // Arrange — Spring 2026 window, from midFall2025's viewpoint.
        let enrolled = [
            course(id: 1, start: "2026-01-12T05:00:00.000Z", end: "2026-05-10T04:59:00.000Z"),
            course(id: 2, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z"),
        ]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [2])
    }

    @Test("the window is inclusive at both boundaries")
    func boundariesAreInclusive() {
        // Arrange — one course starting exactly now, one ending exactly now.
        // "Your course disappeared at the stroke of its end date" is correct;
        // disappearing one second BEFORE it would not be.
        let iso = "2025-10-01T00:00:00.000Z"  // == midFall2025 exactly
        let enrolled = [
            course(id: 1, start: iso, end: "2025-12-29T04:59:00.000Z"),
            course(id: 2, start: "2025-08-14T04:00:00.000Z", end: iso),
        ]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [1, 2])
    }

    @Test("a nil start with a future end is current — the real STARS 2025 shape")
    func nilStartWithFutureEndIsCurrent() {
        // Arrange
        let enrolled = [course(id: 1, code: "stars_2025", start: nil, end: "2026-01-12T18:01:00.000Z")]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [1])
    }

    @Test("a nil start with a past end is hidden")
    func nilStartWithPastEndIsHidden() {
        // Arrange
        let enrolled = [
            course(id: 1, code: "stars_2025", start: nil, end: "2025-01-12T18:01:00.000Z"),
            course(id: 2, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z"),
        ]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [2])
    }

    @Test("a course with only unparseable dates fails closed — hidden, with the honest tell")
    func unparseableDateFailsClosed() {
        // Arrange — user decision 2026-08-24: if D2L ever changes its date
        // format, courses degrade to "undated" and VANISH rather than fail open.
        // The tell that dates stopped parsing is the "No current courses" line —
        // a silent-looking break, but an honest one, chosen over showing shells.
        let enrolled = [course(id: 1, start: "not-a-date", end: "also-not-a-date")]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert — hidden entirely; the message is the diagnostic.
        #expect(renderedIds(model).isEmpty)
        #expect(headers(model).isEmpty)
        #expect(messages(model) == ["No current courses"])
    }

    @Test("one unparseable bound beside a parseable one keeps the parseable bound's verdict")
    func oneUnparseableBoundIsOpen() {
        // Arrange — only a course with NO parseable date is undated; a single bad
        // bound degrades to a missing (open) bound, so a course whose other bound
        // says "current" stays visible.
        let enrolled = [course(id: 1, start: "not-a-date", end: "2025-12-29T04:59:00.000Z")]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [1])
    }
}

@Suite("Currentness — undated courses and the empty state")
struct CurrentnessRenderingTests {

    @Test("undated courses are hidden, even beside a current course")
    func undatedAreHidden() {
        // Arrange — user decision 2026-08-24: the undated administrative shells
        // (Civics Test, Scholarly Project Milestones) are not being taken NOW,
        // so they earn no menu space and no network calls. Real classes exist;
        // "Other" is not for shells any more.
        let enrolled = [
            course(id: 9, code: "wl.nc.civics.test", start: nil, end: nil),
            course(id: 1, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z"),
        ]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert — only the current course; no "Other" section appears.
        #expect(renderedIds(model) == [1])
        #expect(!headers(model).contains("Other"))
        #expect(messages(model).isEmpty)
    }

    @Test("a current-but-untermed course still renders under Other")
    func currentUntermedStillGetsOther() {
        // Arrange — the nil-bucket grouping machinery is deliberately kept: a
        // course that IS current but whose code carries no term (STARS 2025's
        // shape) still needs a header, and "which semester?" is unanswerable.
        let enrolled = [
            course(id: 1, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z"),
            course(id: 5, code: "stars_2025", start: nil, end: "2026-01-12T18:01:00.000Z"),
        ]

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert
        #expect(renderedIds(model) == [1, 5])
        #expect(headers(model).last == "Other")
    }

    @Test("no current courses but some exist → honest message, nothing else rendered")
    func breakShowsMessageOnly() {
        // Arrange — everything dated has ended; only an undated shell remains.
        // This is literally today: summer break. Under the 2026-08-24 policy the
        // shell is hidden too, so the break menu is the message and the commands.
        let enrolled = [
            course(id: 1, start: "2025-08-14T04:00:00.000Z", end: "2025-12-29T04:59:00.000Z"),
            course(id: 9, code: "wl.nc.civics.test", start: nil, end: nil),
        ]
        let summer2026 = Date(timeIntervalSince1970: 1_785_024_000)  // 2026-07-31

        // Act
        let model = MenuTranslation.menu(courses: enrolled, lastFetch: summer2026, now: summer2026, baseURL: base)

        // Assert
        #expect(messages(model) == ["No current courses"])
        #expect(renderedIds(model).isEmpty)
        #expect(headers(model).isEmpty)
    }

    @Test("zero enrolled courses keeps the existing 'No enrolled courses' message")
    func zeroCoursesIsUnchanged() {
        // Arrange / Act — a successful fetch that returned nothing.
        let model = MenuTranslation.menu(courses: [], lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert — distinct from "you have courses, none current".
        #expect(messages(model) == ["No enrolled courses"])
    }
}

@Suite("Currentness — the real 27-course payload")
struct CurrentnessRealDataTests {

    /// Independent truth: computed from the fixture JSON by hand (see the jq/python
    /// classification in the session record), NOT by re-running the code under test.
    private static let currentAtMidFall2025: Set<Int> = [
        1360020,  // Fall 2025 CS 25000 - Merge
        1360027,  // Fall 2025 CS 25100-LEC - Merge
        1360055,  // Fall 2025 CS 25100-P06 PSO
        1361997,  // Fall 2025 ECON 57600-004 LEC
        1372751,  // Fall 2025 STAT 35000-018 DIS
        1413404,  // Fall 2025 PHIL 30400-001 LEC
        1415558,  // STARS 2025 (nil start, ends 2026-01-12)
    ]
    /// The undated shells — hidden since the 2026-08-24 policy change.
    private static let undated: Set<Int> = [412690, 440703]  // Civics, Scholarly Project

    @Test("mid-Fall-2025 shows exactly the 7 current of 27 — the undated shells are hidden")
    func midSemesterShowsExactlyTheCurrentSet() throws {
        // Arrange — real bytes through the real parser.
        let courses = try CrossPackageFixture.realCourses

        // Act
        let model = MenuTranslation.menu(courses: courses, lastFetch: midFall2025, now: midFall2025, baseURL: base)

        // Assert — user decision 2026-08-24: current ONLY, no undated shells.
        #expect(Set(renderedIds(model)) == Self.currentAtMidFall2025)
        #expect(Set(renderedIds(model)).isDisjoint(with: Self.undated))
        #expect(messages(model).isEmpty)
    }

    @Test("summer break shows no courses at all, only an honest message")
    func summerBreakIsHonest() throws {
        // Arrange
        let courses = try CrossPackageFixture.realCourses
        let summer2026 = Date(timeIntervalSince1970: 1_785_024_000)  // 2026-07-31

        // Act
        let model = MenuTranslation.menu(courses: courses, lastFetch: summer2026, now: summer2026, baseURL: base)

        // Assert — 25 dated courses all ended, and since 2026-08-24 the two
        // undated shells are hidden too: the break menu is the message alone.
        #expect(messages(model) == ["No current courses"])
        #expect(renderedIds(model).isEmpty)
        #expect(headers(model).isEmpty)
    }
}
