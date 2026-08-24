import Foundation
import Testing

import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// Where the boundaries go (NewVertical-3.md §3.1).
//
// §3.1 chooses standalone hairline rows over in-component lines, and names the
// cost explicitly: "Boundaries become structure you must place (fence-post cases
// are yours)". This file is that cost, paid in tests. Placement is a rule in the
// PURE translation layer — not a decision a component view makes while drawing —
// so it is testable with plain values and nothing else.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE FENCE-POST CASES ARE RIGHT. The tradeoff table's "Stacking" row is the
//      whole reason this decision was made: in-component lines double at every
//      boundary. A placement rule that emits a trailing hairline after the last
//      course, or two in a row between groups, reintroduces exactly the doubling
//      the design bought its way out of. One line per boundary, explicit.
//
//   2. NOTHING ELSE MOVED. Boundaries are inserted into a row list that other
//      suites, the assembler, and the GUI's Equatable skip-rebuild all read. The
//      courses, their order, their grouping, and the footer must come out
//      byte-identical to before — a hairline rule that also perturbed grouping
//      would be caught here rather than by a confusing failure three files away.
//
// CULLED: colour, thickness, inset, row height — the view's, pinned as structure
// (class + frame, never pixel colours) in
// `Modules/BrightspaceBar/Tests/HairlineRenderingTests.swift`. Also culled:
// re-testing url derivation, subtitles, grouping order and status text, all of
// which `MenuTranslationTests` already owns; this file asserts only what the new
// rule changes.
//
// SCOPE: all small. Pure function, plain values, no I/O, no clock.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED PLACEMENT — the builder implements exactly this.
//
// At TOP LEVEL, a `.hairline` sits immediately BEFORE every `.course` row:
//
//     .sectionHeader("202620")
//     .hairline                  ← between a header and its first course
//     .course(…)
//     .hairline                  ← between consecutive courses
//     .course(…)
//     .sectionHeader("202610")
//     .hairline
//     .course(…)
//     .separator                 ← UNCHANGED: the footer stays a native separator
//     .status(…)
//     .command(.refresh)
//     .command(.quit)
//
// Equivalently: one hairline per course, never two adjacent, never trailing.
//
// SUBMENUS NEVER CONTAIN HAIRLINES. A submenu is one course's own assignments;
// there is no boundary in it to draw.
//
// The footer `.separator` before the status row is deliberately left alone —
// converting it is out of this slice's scope.
// ─────────────────────────────────────────────────────────────────────────────

/// A course with a wide-open Access window, so it is CURRENT at any test `now` and
/// these tests are not entangled with the currentness policy (which
/// `CurrentnessTests` owns).
private func makeCourse(id: Int, code: String = "wl.202610.CS.10000.LE1") -> Course {
    Course(
        id: id, name: "Course \(id)", code: code, role: "Learner", isActive: true,
        homeUrl: nil,
        startDate: "2000-01-01T00:00:00.000Z", endDate: "2999-01-01T00:00:00.000Z"
    )
}

private let epoch = Date(timeIntervalSince1970: 1_786_230_000)

/// The row kinds as bare labels, so an expected SEQUENCE can be written out in
/// full without restating every course's payload. Payloads are already pinned by
/// `MenuTranslationTests`; what this file is about is order.
private func shape(_ rows: [MenuRow]) -> [String] {
    rows.map { row in
        switch row {
        case .course: "course"
        case .assignment: "assignment"
        case .announcement: "announcement"
        case .sectionHeader: "header"
        case .message: "message"
        case .status: "status"
        case .separator: "separator"
        case .command: "command"
        case .hairline: "hairline"
        case .addForm: "addForm"
        }
    }
}

@Suite("MenuTranslation — hairline placement")
struct HairlinePlacementTests {

    // ── Priority 1: the fence-post cases ─────────────────────────────────────

    @Test("a single-term menu reads header, hairline, course, hairline, course")
    func oneGroupGetsABoundaryBeforeEachCourse() {
        // Arrange — two courses under one term: the smallest model that shows both
        // fence posts at once, the header→first-course boundary and the
        // course→course boundary.
        let courses = [
            makeCourse(id: 1, code: "wl.202610.CS.25100.LE1"),
            makeCourse(id: 2, code: "wl.202610.STAT.35000.018"),
        ]

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — the whole sequence, written from the pinned policy above rather
        // than derived from the output. Two courses render, so the menu leads
        // with the "All classes" fold and its separator (aggregate row,
        // Intent 3) — an unbounded prelude, not part of the hairline rule.
        #expect(shape(model.rows) == [
            "course", "separator",
            "header", "hairline", "course", "hairline", "course",
            "separator", "command", "command",
        ])
    }

    @Test("each group's first course gets its own boundary under its header")
    func everyGroupRepeatsTheHeaderBoundary() {
        // Arrange — two terms, so the rule is exercised at a group edge and not
        // just once at the top of the menu.
        let courses = [
            makeCourse(id: 1, code: "wl.202620.CS.25200.LE1"),
            makeCourse(id: 2, code: "wl.202610.CS.25100.LE1"),
            makeCourse(id: 3, code: "wl.202610.STAT.35000.018"),
        ]

        // Act
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — the aggregate prelude leads (aggregate row, Intent 3), then
        // the grouped shape as before.
        #expect(shape(model.rows) == [
            "course", "separator",
            "header", "hairline", "course",
            "header", "hairline", "course", "hairline", "course",
            "separator", "command", "command",
        ])
    }

    @Test("no hairline follows the last course")
    func thereIsNoTrailingBoundary() throws {
        // Arrange — the fence-post error in the other direction. A trailing
        // hairline would stack against the footer separator, which is precisely
        // the doubling §3.1's tradeoff table rejects.
        let courses = (1...3).map { makeCourse(id: $0, code: "wl.202610.CS.2510\($0).LE1") }
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Act
        let lastCourse = try #require(
            model.rows.lastIndex { if case .course = $0 { true } else { false } }
        )

        // Assert
        #expect(model.rows[lastCourse + 1] == .separator)
    }

    @Test("no two boundaries are ever adjacent")
    func boundariesNeverStack() throws {
        // Arrange — the real 27-course payload through the real parser, which is
        // where an untested grouping edge (untermed courses under "Other", a group
        // of exactly one) would actually surface.
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: RealData.midFall2025,
            now: RealData.midFall2025, baseURL: RealData.baseURL
        )

        // Act
        let doubled = model.rows.indices.dropLast().filter {
            model.rows[$0] == .hairline && model.rows[$0 + 1] == .hairline
        }

        // Assert — guard first, or a translation emitting no hairlines at all
        // passes vacuously.
        try #require(model.rows.contains(.hairline), "no boundaries were placed at all")
        #expect(doubled.isEmpty, "boundaries stack at rows \(doubled)")
    }

    @Test("there is exactly one boundary per course")
    func countMatchesTheCourses() throws {
        // Arrange — the whole-menu form of the rule, on real data.
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: RealData.midFall2025,
            now: RealData.midFall2025, baseURL: RealData.baseURL
        )

        // Act
        let hairlines = model.rows.count { $0 == .hairline }

        // Assert — one boundary per REAL course: the "All classes" fold
        // (id == -1 — aggregate row, Intent 3) sits above the headers and is
        // bounded by its own separator, not a hairline.
        let realCourses = model.courses.filter { $0.id != -1 }
        try #require(!realCourses.isEmpty)
        #expect(hairlines == realCourses.count)
    }

    @Test("every course row has a hairline immediately above it")
    func everyCourseIsPreceded() throws {
        // Arrange
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: RealData.midFall2025,
            now: RealData.midFall2025, baseURL: RealData.baseURL
        )

        // Act — the local claim, stated per row rather than as a total, so a menu
        // with the right COUNT of hairlines in the wrong PLACES still fails.
        // The leading "All classes" fold (id == -1 — aggregate row, Intent 3)
        // is deliberately unbounded: it sits above the headers with its own
        // separator, so the per-course rule applies to real courses only.
        let rows = model.rows
        let unbounded = rows.indices.filter { index in
            guard case .course(let course) = rows[index], course.id != -1 else { return false }
            return index == 0 || rows[index - 1] != .hairline
        }

        // Assert
        #expect(unbounded.isEmpty, "courses at \(unbounded) have no boundary above them")
    }

    @Test("the \"no current courses\" break menu has no boundaries — message, separator, commands")
    func theBreakMenuHasNoBoundaries() {
        // Arrange — a semester break. Since the 2026-08-24 user decision the
        // undated administrative shells are hidden along with ended terms, so a
        // break renders NO course rows at all — the message never coexists with
        // a hairline any more, and a stray boundary here would draw a line
        // across an otherwise bare menu. Built with dated-but-out-of-term
        // courses plus an undated shell, so both hidden classes are exercised.
        let ended = Course(
            id: 1, name: "Course 1", code: "wl.202610.CS.25100.LE1",
            role: "Learner", isActive: true, homeUrl: nil,
            startDate: "2025-08-14T04:00:00.000Z", endDate: "2025-12-29T04:59:00.000Z"
        )
        let shell = Course(
            id: 412_690, name: "Course 412690", code: "wl.nc.civics.test",
            role: "Learner", isActive: true, homeUrl: nil,
            startDate: nil, endDate: nil
        )
        let summer2026 = Date(timeIntervalSince1970: 1_785_024_000)  // 2026-07-31

        // Act
        let model = MenuTranslation.menu(
            courses: [ended, shell], lastFetch: summer2026, now: summer2026,
            baseURL: RealData.baseURL
        )

        // Assert — the whole sequence: message, footer, nothing bounded.
        #expect(shape(model.rows) == [
            "message", "separator", "command", "command",
        ])
    }

    @Test("a current-but-untermed course still gets its boundary under the Other header")
    func theOtherGroupStillBoundsItsCourses() {
        // Arrange — the nil-bucket machinery is intentionally kept: a course
        // that is current but untermed (STARS 2025's shape — nil start, real
        // future end) renders under "Other", and the hairline rule must hold
        // there exactly as under a term header.
        let termed = makeCourse(id: 1, code: "wl.202610.CS.25100.LE1")
        let stars = Course(
            id: 1_415_558, name: "STARS 2025", code: "stars_2025",
            role: "Learner", isActive: true, homeUrl: nil,
            startDate: nil, endDate: "2999-01-01T00:00:00.000Z"
        )

        // Act
        let model = MenuTranslation.menu(
            courses: [termed, stars], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert — with two rendered courses the aggregate prelude leads
        // (aggregate row, Intent 3); the Other group's boundary holds after it.
        #expect(shape(model.rows) == [
            "course", "separator",
            "header", "hairline", "course",
            "header", "hairline", "course",
            "separator", "command", "command",
        ])
    }

    // ── Priority 2: nothing else moved ───────────────────────────────────────

    @Test("submenus contain no boundaries")
    func submenusStayFlat() throws {
        // Arrange — real assignments, so the submenu is genuinely populated rather
        // than empty (an empty submenu would satisfy this vacuously).
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: RealData.midFall2025,
            now: RealData.midFall2025, baseURL: RealData.baseURL
        )

        // Act
        let submenuRows = model.courses.flatMap(\.submenu)

        // Assert
        #expect(!submenuRows.contains(.hairline))
    }

    @Test("the empty-enrollment menu has no boundaries at all")
    func noCoursesMeansNoBoundaries() {
        // Arrange / Act — a successful fetch that returned nothing. With no course
        // rows there is nothing to bound, and a stray hairline would draw a line
        // across an otherwise bare menu.
        let model = MenuTranslation.menu(
            courses: [], lastFetch: epoch, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(!model.rows.contains(.hairline))
    }

    @Test("the cold-start placeholder is unchanged")
    func placeholderGainsNoBoundary() {
        // Arrange / Act — the placeholder is a frozen constant on the contract and
        // the GUI compares against it by value; growing a hairline would change a
        // shape this slice has no business touching.
        let model = MenuTranslation.menu(
            courses: [], lastFetch: nil, now: epoch, baseURL: RealData.baseURL
        )

        // Assert
        #expect(model == MenuModel.placeholder)
        #expect(!MenuModel.placeholder.rows.contains(.hairline))
    }

    @Test("boundaries do not disturb the courses, their order, or the footer")
    func everythingElseIsUntouched() throws {
        // Arrange — the regression guard for the whole slice: strip the hairlines
        // back out and the model must be exactly what it was before this feature.
        let courses = try CrossPackageFixture.realCourses
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: RealData.midFall2025,
            now: RealData.midFall2025, baseURL: RealData.baseURL
        )

        // Act — strip the hairlines AND the leading "All classes" fold with its
        // separator (aggregate row, Intent 3): both features are additive, so
        // what remains must be exactly the pre-feature shape.
        let withoutBoundaries = Array(model.rows.dropFirst(2)).filter { $0 != .hairline }

        // Assert — the pre-hairline shape, stated independently: grouped headers
        // and courses, then the footer.
        try #require(!withoutBoundaries.isEmpty)
        #expect(shape(withoutBoundaries).suffix(3) == ["separator", "command", "command"])
        #expect(!shape(withoutBoundaries).dropLast(3).contains("separator"))
        #expect(withoutBoundaries.compactMap { if case .course(let c) = $0 { c.id } else { nil } }
            == model.courses.map(\.id).filter { $0 != -1 })
    }
}
