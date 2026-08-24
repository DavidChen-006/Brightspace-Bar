import Foundation
import Testing

import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// MenuTranslation — the pure core of the wiring: [Course] → MenuModel.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. CLICK-TARGET CORRECTNESS. `CourseRow.url` is derived, not received:
//      `OrgUnit.HomeUrl` is null in 25 of 27 real enrollments, so this function is
//      the ONLY thing that makes a row clickable. Derive the wrong id and the menu
//      looks perfect while sending a student into someone else's course. Nothing
//      downstream can catch it — the GUI just opens whatever URL it is handed.
//
//   2. NO SILENT DATA LOSS. 27 courses in must be 27 rows out. Grouping, sorting,
//      and short-code derivation all have to partition the list without dropping a
//      course whose code has an unexpected shape — and 4 of 27 real codes DO have
//      an unexpected shape (`stars_2025`, `wl.nc.civics.test`, and two more).
//
// CULLED: cosmetic polish (font, indentation, truncation — not this function's
// job), localization (single-locale app), performance (27 rows), and any claim
// about what a term code *means* (see the note on labels below).
//
// SCOPE: all Google-small. Pure function, plain values, no I/O, no clock — `now`
// is a parameter. The real 27-course payload is read from disk, which is I/O, but
// only to obtain inputs; the behaviour under test is pure.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED DERIVATIONS — the builder implements exactly these.
//
// ── url ──────────────────────────────────────────────────────────────────────
//   "{baseURL}/d2l/home/{id}", uniformly, for EVERY course. `Course.homeUrl` is
//   never read. The two real courses that do carry one must derive identically to
//   the other 25 — a menu where two rows follow a different rule is worse than one
//   that ignores the field entirely.
//
// ── subtitle ─────────────────────────────────────────────────────────────────
//   The human course code, derived from `Course.code`:
//       "wl.202610.CS.25100.LE1"  →  "CS 25100"
//       "stars_2025"              →  nil
//       "wl.nc.civics.test"       →  nil
//   Rule: split on ".". If there are at least 5 components, component 1 is exactly
//   6 digits, and component 3 is all digits, then "\(component 2) \(component 3)".
//   Otherwise nil. Undecodable shapes yield nil — they never drop the course.
//
// ── title ────────────────────────────────────────────────────────────────────
//   `Course.name`, VERBATIM.
//
//   NOTE FOR THE ORCHESTRATOR — a real cosmetic wart, deliberately not "fixed"
//   here. D2L's `Name` already embeds the term and code: the SPEC's illustrative
//   "CS 17600 — Data Engineering" does not exist in the data. Real names are
//   "Fall 2025 CS 25100-LEC - Merge". Combined with the GUI's pinned
//   "subtitle — title" format, a row reads:
//
//       "CS 25100 — Fall 2025 CS 25100-LEC - Merge"
//
//   which is redundant. Stripping the leading term and the "- Merge" suffix would
//   read better, but that is a name-mangling heuristic that can be wrong
//   ("Spring 2026 MA/STAT 416 - Merge" is not "MA 41600"), and inventing one is a
//   product decision, not a test-writer's. Faithful preservation is experiment 4's
//   whole ethos and I am keeping it. Flagging for a human call.
//
// ── section headers ──────────────────────────────────────────────────────────
//   The raw term code ("202610"), descending. Untermed courses go last under
//   "Other". No term is mapped to a season/year name: Purdue's encoding is not
//   verified here and a confidently wrong "Fall 2025" is worse than a raw code.
//
// ── order WITHIN a group ─────────────────────────────────────────────────────
//   By `Course.code` ascending.
//
//   This has to be pinned to something input-independent. Grouping is naturally
//   written with a Dictionary, and Swift dictionaries have no guaranteed iteration
//   order — so without an explicit sort the menu would silently reshuffle itself
//   between refreshes, and `MenuModel`'s `Equatable` (which the GUI uses to skip
//   rebuilding) would compare unequal on identical data. Sorting by code also
//   reads well: it clusters a department together and keeps a lecture next to its
//   own recitation (`…CS.25100.LE1` before `…CS.25100.P06`).
//
// ── status ───────────────────────────────────────────────────────────────────
//   lastFetch nil        →  "Never updated"
//   age < 60s            →  "Updated just now"      (including negative age)
//   60s ≤ age < 3600s    →  "Updated N minutes ago" / "Updated 1 minute ago"
//   age ≥ 3600s          →  "Updated N hours ago"   / "Updated 1 hour ago"
//
//   Negative age folds into "just now" rather than "Updated -3 minutes ago":
//   experiment 4 already treats a future timestamp as untrustworthy, and the menu
//   must not display arithmetic at the user.
//
// ── overall shape ────────────────────────────────────────────────────────────
//   [headers + courses, grouped] + .separator + .status + .refresh + .quit
//
//   Empty courses + nil lastFetch  →  exactly MenuModel.placeholder
//   Empty courses + a lastFetch    →  a message, a status, and the commands
// ─────────────────────────────────────────────────────────────────────────────

/// Expected values, built independently of the production code. Nothing here calls
/// into `MenuTranslation`, so an implementation bug cannot define its own answer.
private enum Expected {
    static let untermedHeader = "Other"

    static func url(id: Int) -> URL {
        URL(string: "https://purdue.brightspace.com/d2l/home/" + String(id))!
    }

    static func status(secondsAgo: TimeInterval?) -> String {
        guard let secondsAgo else { return "Never updated" }
        if secondsAgo < 60 { return "Updated just now" }
        if secondsAgo < 3600 {
            let m = Int(secondsAgo / 60)
            return "Updated \(m) minute" + (m == 1 ? "" : "s") + " ago"
        }
        let h = Int(secondsAgo / 3600)
        return "Updated \(h) hour" + (h == 1 ? "" : "s") + " ago"
    }
}

/// Convenience accessors so assertions read as claims rather than as pattern matching.
private extension MenuModel {
    var headers: [String] {
        self.rows.compactMap { if case .sectionHeader(let s) = $0 { s } else { nil } }
    }
    var statuses: [String] {
        self.rows.compactMap { if case .status(let s) = $0 { s } else { nil } }
    }
    var messages: [String] {
        self.rows.compactMap { if case .message(let s) = $0 { s } else { nil } }
    }
    var commands: [MenuCommand] {
        self.rows.compactMap { if case .command(let c) = $0 { c } else { nil } }
    }
    func row(id: Int) -> CourseRow? {
        self.courses.first { $0.id == id }
    }
}

private func makeCourse(
    id: Int,
    name: String = "Some Course",
    code: String = "wl.202610.CS.10000.LE1",
    homeUrl: String? = nil
) -> Course {
    Course(id: id, name: name, code: code, role: "Learner", isActive: true, homeUrl: homeUrl)
}

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

@Suite("MenuTranslation — [Course] to MenuModel")
struct MenuTranslationTests {

    // ── Priority 1: click-target correctness ─────────────────────────────────

    @Test("every course row's url is derived from its own id")
    func urlIsDerivedFromTheCoursesOwnID() throws {
        // Arrange — several courses so an off-by-one cannot pass by luck, with
        // deliberately non-adjacent ids so a shifted index yields a wrong number
        // rather than a coincidentally-right one.
        let ids = [412_690, 1_095_299, 1_360_027, 1_488_325, 1_498_777]
        let courses = ids.map { makeCourse(id: $0) }

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — guard the count first, or a translation that emits nothing
        // would pass this test vacuously.
        try #require(model.courses.count == ids.count)
        for id in ids {
            let row = try #require(model.row(id: id), "no row for course \(id)")
            #expect(row.url == Expected.url(id: id))
        }
    }

    @Test("a course carrying a non-nil homeUrl still derives its url the same way")
    func homeUrlIsIgnoredSoDerivationStaysUniform() throws {
        // Arrange — 412690 is one of only two real courses with a HomeUrl. Hand it
        // a deliberately WRONG stored value; if the implementation prefers the
        // field over derivation, this fails loudly.
        let withHomeUrl = makeCourse(
            id: 412_690,
            code: "wl.nc.civics.test",
            homeUrl: "https://example.invalid/not-the-real-place"
        )
        let withoutHomeUrl = makeCourse(id: 1_360_027)

        // Act
        let model = MenuTranslation.menu(
            courses: [withHomeUrl, withoutHomeUrl],
            lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        try #require(model.courses.count == 2)
        let derived = try #require(model.row(id: 412_690))
        #expect(derived.url == Expected.url(id: 412_690))
        #expect(derived.url.absoluteString.contains("example.invalid") == false)
    }

    @Test("a baseURL with a trailing slash does not produce a doubled slash")
    func trailingSlashInBaseURLIsHandled() throws {
        // Arrange — a caller passing "https://host/" is entirely plausible, and
        // ".../d2l/home//412690" is a different URL that may not resolve.
        let base = try #require(URL(string: "https://purdue.brightspace.com/"))

        // Act
        let model = MenuTranslation.menu(
            courses: [makeCourse(id: 412_690)], lastFetch: epoch, now: epoch, baseURL: base
        )

        // Assert
        let row = try #require(model.courses.first)
        #expect(row.url.absoluteString == "https://purdue.brightspace.com/d2l/home/412690")
    }

    // ── Priority 2: no silent data loss ──────────────────────────────────────

    @Test("all 27 real courses survive translation")
    func realPayloadYieldsTwentySevenRows() throws {
        // Arrange — the genuine bytes through the genuine parser, so this is the
        // real chain and not hand-built data.
        let courses = try CrossPackageFixture.realCourses
        try #require(courses.count == RealData.totalCourses)

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model.courses.count == RealData.totalCourses)
    }

    @Test("every real course id appears exactly once")
    func noCourseIsDroppedOrDuplicated() throws {
        // Arrange
        let courses = try CrossPackageFixture.realCourses
        let expectedIDs = Set(courses.map(\.id))
        try #require(expectedIDs.count == RealData.totalCourses)

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        let actualIDs = model.courses.map(\.id)
        #expect(Set(actualIDs) == expectedIDs)
        #expect(actualIDs.count == RealData.totalCourses, "an id was duplicated")
    }

    @Test("a course whose code has an unrecognised shape is kept, not dropped")
    func unparseableCodeStillYieldsARow() throws {
        // Arrange — 4 of 27 real codes are not `wl.TERM.DEPT.NUM.SEC`. Dropping
        // them would silently lose a quarter of the untermed courses.
        let odd = [
            makeCourse(id: 1_415_558, name: "STARS 2025", code: "stars_2025"),
            makeCourse(id: 440_703, name: "Scholarly Project Milestones", code: "scholarly_project_milestones"),
            makeCourse(id: 412_690, name: "Purdue Civics Knowledge Test", code: "wl.nc.civics.test"),
            makeCourse(id: 1_139_395, name: "Honors College Orientation 2024", code: "honors_college_orientation_2024"),
            makeCourse(id: 999_001, name: "Empty Code", code: ""),
        ]

        // Act
        let model = MenuTranslation.menu(
            courses: odd, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model.courses.count == odd.count)
    }

    // ── Derivations: subtitle ────────────────────────────────────────────────

    @Test(
        "a well-formed code yields a human short code as the subtitle",
        arguments: [
            ("wl.202610.CS.25100.LE1", "CS 25100"),
            ("wl.202620.CS.25200.LE1", "CS 25200"),
            ("wl.202510.MA.16200.100", "MA 16200"),
            ("wl.202620.MA.41600.008", "MA 41600"),
            ("wl.202610.STAT.35000.018", "STAT 35000"),
            ("wl.202520.HONR.19902.H21", "HONR 19902"),
        ]
    )
    func wellFormedCodeYieldsShortCode(code: String, expected: String) throws {
        // Arrange
        let course = makeCourse(id: 1, code: code)

        // Act
        let model = MenuTranslation.menu(
            courses: [course], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        let row = try #require(model.courses.first)
        #expect(row.subtitle == expected)
    }

    @Test(
        "a code with no derivable course number yields no subtitle",
        arguments: [
            "stars_2025",
            "scholarly_project_milestones",
            "honors_college_orientation_2024",
            "wl.nc.civics.test",
            "",
            "wl.202610",
            "wl.202610.CS",
        ]
    )
    func undecodableCodeYieldsNilSubtitle(code: String) throws {
        // Arrange
        let course = makeCourse(id: 1, code: code)

        // Act
        let model = MenuTranslation.menu(
            courses: [course], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — nil, and emphatically not the string "nil" or an empty string,
        // either of which would render as a dangling em dash in the GUI.
        let row = try #require(model.courses.first)
        #expect(row.subtitle == nil)
    }

    // ── Derivations: title ──────────────────────────────────────────────────

    @Test("the row title is the course name verbatim")
    func titleIsTheCourseNameUntouched() throws {
        // Arrange — a real name, including the "- Merge" suffix and the embedded
        // term that a well-meaning cleanup would strip.
        let course = makeCourse(
            id: RealData.dataStructuresID,
            name: RealData.dataStructuresName,
            code: RealData.dataStructuresCode
        )

        // Act
        let model = MenuTranslation.menu(
            courses: [course], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        let row = try #require(model.courses.first)
        #expect(row.title == RealData.dataStructuresName)
        #expect(row.subtitle == RealData.dataStructuresShortCode)
    }

    // ── Derivations: term grouping ──────────────────────────────────────────

    @Test("terms appear newest first with untermed courses last")
    func termsAreDescendingAndUntermedComesLast() throws {
        // Arrange — deliberately shuffled input so a passing test cannot be an
        // artifact of the input already being in order.
        let courses = try CrossPackageFixture.realCourses.shuffled()

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        let expected = RealData.termsDescending + [Expected.untermedHeader]
        #expect(model.headers == expected)
    }

    @Test("each term group holds exactly its own courses")
    func groupMembershipMatchesTheData() throws {
        // Arrange
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Act — walk the rows, attributing each course to the header above it.
        var counts: [String: Int] = [:]
        var current: String?
        for row in model.rows {
            switch row {
            case .sectionHeader(let name): current = name
            case .course: if let current { counts[current, default: 0] += 1 }
            default: break
            }
        }

        // Assert
        try #require(!counts.isEmpty, "no course was attributed to any header")
        for (term, expected) in RealData.countsByTerm {
            #expect(counts[term] == expected, "term \(term) held \(counts[term] ?? 0), expected \(expected)")
        }
        #expect(counts[Expected.untermedHeader] == RealData.untermedCount)
    }

    @Test("courses within a term are ordered by code")
    func withinATermCoursesAreSortedByCode() throws {
        // Arrange — presented deliberately out of order, including a lecture and
        // its recitation which share a course number.
        let courses = [
            makeCourse(id: 4, code: "wl.202610.STAT.35000.018"),
            makeCourse(id: 2, code: "wl.202610.CS.25100.P06"),
            makeCourse(id: 1, code: "wl.202610.CS.25100.LE1"),
            makeCourse(id: 3, code: "wl.202610.ECON.57600.004"),
        ]

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — ids ordered as their codes sort, not as they were handed over.
        try #require(model.courses.count == 4)
        #expect(model.courses.map(\.id) == [1, 2, 3, 4])
    }

    @Test("a single-term list still carries its header")
    func oneTermStillGetsAHeader() throws {
        // Arrange
        let courses = [
            makeCourse(id: 1, code: "wl.202620.CS.25200.LE1"),
            makeCourse(id: 2, code: "wl.202620.CS.47100.LE1"),
        ]

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model.headers == ["202620"])
        #expect(model.courses.count == 2)
    }

    // ── Derivations: status ─────────────────────────────────────────────────

    @Test(
        "the status row reports how long ago the data was fetched",
        arguments: [
            (TimeInterval(0), "Updated just now"),
            (TimeInterval(59), "Updated just now"),
            (TimeInterval(60), "Updated 1 minute ago"),
            (TimeInterval(120), "Updated 2 minutes ago"),
            (TimeInterval(3599), "Updated 59 minutes ago"),
            (TimeInterval(3600), "Updated 1 hour ago"),
            (TimeInterval(7200), "Updated 2 hours ago"),
        ]
    )
    func statusReflectsAge(age: TimeInterval, expected: String) throws {
        // Arrange
        let lastFetch = epoch
        let now = epoch.addingTimeInterval(age)

        // Act
        let model = MenuTranslation.menu(
            courses: [makeCourse(id: 1)], lastFetch: lastFetch, now: now, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model.statuses == [expected])
        #expect(expected == Expected.status(secondsAgo: age), "expectation table disagrees with itself")
    }

    @Test("a never-fetched list with courses still reports honestly")
    func nilLastFetchWithCoursesSaysNeverUpdated() throws {
        // Arrange — courses present but no timestamp. Reachable if a cache file is
        // hand-placed, or if the format ever changes.
        let model = MenuTranslation.menu(
            courses: [makeCourse(id: 1)], lastFetch: nil, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model.statuses == ["Never updated"])
    }

    @Test("a future lastFetch does not render negative arithmetic")
    func futureTimestampFoldsIntoJustNow() throws {
        // Arrange — clock skew and waking from sleep both produce this; experiment
        // 4 already treats it as untrustworthy rather than trusting the sign.
        let lastFetch = epoch.addingTimeInterval(600)

        // Act
        let model = MenuTranslation.menu(
            courses: [makeCourse(id: 1)], lastFetch: lastFetch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        let status = try #require(model.statuses.first)
        #expect(status == "Updated just now")
        #expect(!status.contains("-"), "a negative age reached the user: \(status)")
    }

    // ── Shape and the empty cases ───────────────────────────────────────────

    @Test("a populated menu ends with a status row and both commands")
    func populatedMenuCarriesStatusAndCommands() throws {
        // Arrange
        let courses = try CrossPackageFixture.realCourses

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — the user must always have a way to refresh and a way out.
        #expect(model.commands == [.refresh, .quit])
        #expect(model.statuses.count == 1)
    }

    @Test("no course row appears after the commands")
    func commandsComeLast() throws {
        // Arrange
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Act
        let firstCommandIndex = model.rows.firstIndex { if case .command = $0 { true } else { false } }
        let lastCourseIndex = model.rows.lastIndex { if case .course = $0 { true } else { false } }

        // Assert
        let commandAt = try #require(firstCommandIndex, "no command row at all")
        let courseAt = try #require(lastCourseIndex, "no course row at all")
        #expect(courseAt < commandAt)
    }

    @Test("no courses and no timestamp yields exactly the placeholder")
    func coldStateIsThePlaceholder() {
        // Arrange / Act — the cold-start state: nothing loaded, nothing fetched.
        let model = MenuTranslation.menu(
            courses: [], lastFetch: nil, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model == MenuModel.placeholder)
    }

    @Test("a genuinely empty enrollment is distinguishable from a cold start")
    func emptyAfterAFetchSaysSomethingDifferent() throws {
        // Arrange — a successful fetch that returned zero courses is real data, and
        // must not be presented as "haven't loaded yet".
        let model = MenuTranslation.menu(
            courses: [], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model != MenuModel.placeholder)
        #expect(!model.messages.isEmpty, "an empty list must explain itself")
        #expect(model.statuses == ["Updated just now"])
        #expect(model.commands.contains(.refresh))
    }

    @Test("an empty menu is never zero rows")
    func emptyIsNeverBlank() {
        // Arrange / Act — a dropdown with no rows reads as a crashed app, which is
        // why this holds for both empty shapes.
        let cold = MenuTranslation.menu(
            courses: [], lastFetch: nil, now: epoch, baseURL: RealData.baseURL
        )
        let fetchedEmpty = MenuTranslation.menu(
            courses: [], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(!cold.rows.isEmpty)
        #expect(!fetchedEmpty.rows.isEmpty)
    }

    @Test("translation is deterministic for the same inputs")
    func sameInputsYieldTheSameModel() throws {
        // Arrange — grouping via a dictionary is the obvious implementation and
        // dictionaries have no order, so an unsorted grouping would make the menu
        // reshuffle itself between refreshes. `Equatable` on MenuModel is also what
        // the GUI relies on to skip rebuilding.
        let courses = try CrossPackageFixture.realCourses

        // Act
        let a = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )
        let b = MenuTranslation.menu(
            courses: courses.shuffled(), lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — the count guard is load-bearing, not decoration. Without it this
        // test passes against a translation that returns nothing at all, since two
        // empty models are trivially equal. Verified: it did exactly that against a
        // do-nothing stub until this guard was added.
        try #require(a.courses.count == RealData.totalCourses)
        try #require(!a.headers.isEmpty)
        #expect(a == b, "translation depends on input order or on dictionary iteration order")
    }
}
