import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE DAY POPUP'S CONTENT — items due on day D, for course C (Intent 2).
//
// The hover popup is AppKit; its CONTENT is not. Everything the popup says —
// which cells answer at all, what the caption reads, which items appear, in
// what order, and where each row's click lands — is decided in
// `GraphTranslation.strip`'s detail half, a pure function pinned here.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE POPUP AND THE SQUARE MUST BE TWO READINGS OF ONE BUCKETING. A cell
//      that is filled but silent on hover, or a popup on an empty-looking day,
//      reads as a broken feature; worse, a popup listing a NEIGHBOURING day's
//      items is perfectly plausible and mis-dates real work. So the invariant
//      is pinned directly: detail exists exactly where tier does, and the
//      caption names the same local day the bucketing chose — including for the
//      23:30-local instant whose UTC day is tomorrow.
//
//   2. THE DEEP LINKS MUST BE THE SUBMENU'S. A popup row and its submenu row
//      describe the same item; two templates would eventually send them to two
//      pages. The exact browser-verified URLs (experiment 7 for dropbox,
//      the 2026-08-10 probe for quizzes) are restated here as literals, and
//      `ou=` must come from the strip's course parameter, never from
//      `Assignment.courseId` — the same transposition defence the submenu pins.
//
// CULLED: window arithmetic, tier ranking, isToday — all already pinned by
// `GraphTranslationTests` over the same fold. And everything about how the
// popup is SHOWN (anchoring, grace delay) — the anchoring math is pinned in the
// GUI module's own suite, and the rest is hand-verified in stub mode.
//
// SCOPE: all small. Pure translation over plain values, `now`/`timeZone`
// injected, no clock and no locale anywhere.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED INSTANT — the same Tuesday `GraphTranslationTests` pins, so the two
// suites describe one window. 2026-02-10T15:00:00Z = 10:00 on TUE FEB 10 in
// Indiana; the window opens Sun Feb 8, today is cell 2.
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    static let zone = TimeZone(identifier: "America/Indianapolis")!
    static let now = Date(timeIntervalSince1970: 1_770_735_600)

    /// 15:00 local on **Wed Feb 11** = `2026-02-11T20:00:00Z`. Cell 3.
    static let wednesdayAfternoon = Date(timeIntervalSince1970: 1_770_840_000)
    /// **23:30 local on Thu Feb 12** = `2026-02-13T04:30:00Z`. Cell 4 — the UTC
    /// day reads Feb 13; the caption must say Thu Feb 12.
    static let lateNightOnFebTwelfth = Date(timeIntervalSince1970: 1_770_957_000)

    static let baseURL = URL(string: "https://purdue.brightspace.com")!
    static let courseId = 445_296
    static let courseLabel = "CS 25200"
}

private func work(
    _ id: Int,
    _ kind: ItemKind,
    due dueDate: Date?,
    name: String? = nil,
    isHidden: Bool = false,
    courseId: Int = Pinned.courseId
) -> Assignment {
    Assignment(
        id: id, courseId: courseId, name: name ?? "Item \(id)", dueDate: dueDate,
        isHidden: isHidden, groupTypeId: nil, kind: kind
    )
}

/// The strip WITH link context — the shape `MenuTranslation` builds.
private func detailedStrip(_ items: [Assignment], courseLabel: String? = Pinned.courseLabel) -> [GraphCell] {
    GraphTranslation.strip(
        state: .loaded(items), now: Pinned.now, timeZone: Pinned.zone,
        courseId: Pinned.courseId, courseLabel: courseLabel, baseURL: Pinned.baseURL
    )
}

@Suite("Graph day details — the hover popup's content, as pure values")
struct GraphDayDetailTests {

    // MARK: - Where a detail exists at all

    @Test("detail exists exactly where a tier does — popup and square agree")
    func detailExistsExactlyWhereATierDoes() {
        let cells = detailedStrip([
            work(1, .assignment, due: Pinned.wednesdayAfternoon),
            work(2, .quiz, due: Pinned.lateNightOnFebTwelfth),
        ])
        for cell in cells {
            #expect((cell.tier == nil) == (cell.detail == nil))
        }
        #expect(cells[3].detail != nil)
        #expect(cells[4].detail != nil)
    }

    @Test("without link context the strip is exactly what it was — no details")
    func withoutLinkContextThereAreNoDetails() {
        let cells = GraphTranslation.strip(
            state: .loaded([work(1, .assignment, due: Pinned.wednesdayAfternoon)]),
            now: Pinned.now, timeZone: Pinned.zone
        )
        #expect(cells[3].tier == .assignment)
        #expect(cells.allSatisfy { $0.detail == nil })
    }

    @Test("hidden items and gradeOnly columns never reach a popup")
    func hiddenAndGradeOnlyNeverReachAPopup() {
        let cells = detailedStrip([
            work(1, .assignment, due: Pinned.wednesdayAfternoon, isHidden: true),
            work(2, .gradeOnly, due: Pinned.wednesdayAfternoon),
        ])
        #expect(cells.allSatisfy { $0.detail == nil })
    }

    // MARK: - The caption

    @Test("caption names the local day and the course")
    func captionNamesTheLocalDayAndTheCourse() {
        let cells = detailedStrip([work(1, .assignment, due: Pinned.wednesdayAfternoon)])
        #expect(cells[3].detail?.caption == "Wed Feb 11 · CS 25200")
    }

    @Test("caption speaks the LOCAL day — 23:30 local is not tomorrow")
    func captionSpeaksTheLocalDay() {
        // The instant's UTC day is Feb 13; the bucketing (already pinned) files
        // it on Thu Feb 12, and the caption must say the same day the square is
        // on — a caption read off the UTC instant would contradict the grid.
        let cells = detailedStrip([work(1, .quiz, due: Pinned.lateNightOnFebTwelfth)])
        #expect(cells[4].detail?.caption == "Thu Feb 12 · CS 25200")
    }

    @Test("no course label drops the course half, never the day")
    func noCourseLabelDropsTheCourseHalf() {
        let cells = detailedStrip(
            [work(1, .assignment, due: Pinned.wednesdayAfternoon)], courseLabel: nil
        )
        #expect(cells[3].detail?.caption == "Wed Feb 11")
    }

    // MARK: - The rows

    @Test("a day's items are listed with their own tiers, name-sorted, id tie-broken")
    func itemsAreNameSortedWithIdTieBreak() throws {
        let cells = detailedStrip([
            work(9, .quiz, due: Pinned.wednesdayAfternoon, name: "Beta"),
            work(2, .assignment, due: Pinned.wednesdayAfternoon, name: "Alpha"),
            work(1, .assignment, due: Pinned.wednesdayAfternoon, name: "Alpha"),
        ])
        let items = try #require(cells[3].detail).items
        #expect(items.map(\.title) == ["Alpha", "Alpha", "Beta"])
        // Same names sort by id — 1 before 2 — observable through the urls.
        #expect(items[0].url.absoluteString.contains("db=1"))
        #expect(items[1].url.absoluteString.contains("db=2"))
        // Each row carries its OWN tier even though the cell's fill is the max.
        #expect(items.map(\.tier) == [.assignment, .assignment, .quiz])
        #expect(cells[3].tier == .quiz)
    }

    // MARK: - The deep links (the submenu's templates, restated as literals)

    @Test("an assignment row uses the browser-verified dropbox template")
    func assignmentRowUsesTheDropboxTemplate() {
        let cells = detailedStrip([work(476_101, .assignment, due: Pinned.wednesdayAfternoon)])
        #expect(
            cells[3].detail?.items.first?.url.absoluteString
                == "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=476101&grpid=0&ou=445296"
        )
    }

    @Test("a quiz row uses the browser-verified quiz template")
    func quizRowUsesTheQuizTemplate() {
        let cells = detailedStrip([work(476_481, .quiz, due: Pinned.wednesdayAfternoon)])
        #expect(
            cells[3].detail?.items.first?.url.absoluteString
                == "https://purdue.brightspace.com/d2l/lms/quizzing/user/quiz_summary.d2l?qi=476481&ou=445296"
        )
    }

    @Test("ou comes from the strip's course, never from the item")
    func ouComesFromTheStripsCourse() {
        // A fan-out bug stamping another course's id on the item must not leak
        // into the link — the same structural guarantee the submenu pins.
        let cells = detailedStrip([
            work(7, .assignment, due: Pinned.wednesdayAfternoon, courseId: 999_999)
        ])
        #expect(cells[3].detail?.items.first?.url.absoluteString.hasSuffix("ou=445296") == true)
    }

    // MARK: - Wiring

    @Test("MenuTranslation hands every course a detailed strip with its own label")
    func menuTranslationWiresTheLinkContext() {
        let course = Course(
            id: Pinned.courseId, name: "Systems Programming",
            code: "wl.202610.CS.25200.LE1", role: "Student", isActive: true,
            startDate: "2026-01-12T05:00:00.000Z", endDate: "2026-05-10T04:00:00.000Z"
        )
        let model = MenuTranslation.menu(
            courses: [course], lastFetch: Pinned.now, now: Pinned.now,
            baseURL: Pinned.baseURL,
            assignments: [Pinned.courseId: .loaded([
                work(1, .assignment, due: Pinned.wednesdayAfternoon)
            ])],
            timeZone: Pinned.zone
        )
        let detail = model.courses.first?.graph[3].detail
        #expect(detail?.caption == "Wed Feb 11 · CS 25200")
        #expect(detail?.items.count == 1)
    }
}
