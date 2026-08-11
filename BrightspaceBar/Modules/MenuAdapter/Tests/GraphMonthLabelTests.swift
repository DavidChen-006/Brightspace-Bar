import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// MONTH LABELS — the grid's column headings (NewVertical-3.md §5, slice 4).
//
// A 16-column grid of undated squares is unreadable without a scale, and the
// scale is a CALENDAR question, not a layout one: which column holds the first
// of a month depends on where the window opened, which depends on `now` and on
// the time zone. That is the backend's vocabulary, so the labels are derived
// here, beside `strip`, from the same injected clock.
//
// The split this file assumes, and the reason it is drawn where it is:
//
//   MONTH labels are SEMANTIC   → backend (this file)     — they name real days
//   WEEKDAY labels are GEOMETRIC → renderer (slice 4 view) — row 0 is Sunday by
//                                  construction, for every window, forever
//
// A weekday gutter needs no calendar: §3.3's seam already promises the window
// opens on a week boundary, so "row 0 is Sunday" is true of every window the
// backend can emit and the renderer can hard-code it. A month heading is the
// opposite — it is different for every `now`.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. A LABEL OVER THE WRONG COLUMN IS SILENTLY PLAUSIBLE. This is the same
//      failure class as the bucketing in `GraphTranslationTests`: "Apr" one
//      column left of where April starts still reads as a perfectly ordinary
//      grid, and the student mis-reads every deadline under it by a week.
//      Nothing downstream can catch it — the renderer draws whatever strings it
//      is handed, above whatever columns exist. So the arithmetic is pinned
//      against a calendar transcribed by hand, column by column, for windows
//      chosen to break the plausible wrong implementations: stepping by
//      7 × 86_400 seconds (a window crossing the spring-forward), reading the
//      UTC day (a `now` that is a different date in two zones), and assuming
//      the window opens mid-month.
//
//   2. DETERMINISM ACROSS MACHINES AND LOCALES. The names come from a fixed
//      `en_US_POSIX` gregorian formatting, never the ambient locale, for exactly
//      the reason `AssignmentTranslation.dueLabel` pins it: a suite that passes
//      in Indiana and fails in Paris is a suite nobody trusts. LOCALIZATION IS
//      FUTURE WORK and is deliberately not designed for here — when it lands it
//      is a locale parameter threaded through, and these expectations become
//      locale-parameterised with it.
//
// CULLED, and deliberately: where the strings are DRAWN (the top row's height,
// the text's baseline, whether a label is centred over its column or
// left-aligned to it, truncation when two labels would collide) — all geometry,
// pinned as rects in `GraphGridGeometryTests` or verified visually in stub mode;
// the year — the window is under four months, so "Jan" is unambiguous and no
// label carries one; and the weekday gutter's contents, which never vary and are
// the renderer's literal.
//
// SCOPE: all small. A pure function of `(now, timeZone)`. No `Date()`, no
// `TimeZone.current`, no `Locale.current`, anywhere.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//     public enum GraphTranslation {
//         /// One entry per week COLUMN of the window. Pure.
//         public static func monthLabels(now: Date, timeZone: TimeZone) -> [String?]
//     }
//
// (Surfacing it through the existing strip API instead is the builder's call, as
// long as it stays pure and clock-injected; these tests call it by this name.)
//
// ── Shape ───────────────────────────────────────────────────────────────────
//   `windowDays / 7` entries — 16, one per column, always, for every `now`. Not
//   one per labelled column: the renderer indexes this array BY COLUMN, so a
//   compacted array would put every label one place left of its column.
//
// ── Which columns carry a name ──────────────────────────────────────────────
//   • Column 0 ALWAYS carries a name: the month of the WINDOW START. Without it
//     the leftmost columns are unscaled until the first month rolls over, which
//     for a window opening on the 2nd is nearly a month of unlabelled grid.
//   • Every LATER column that contains the 1st of a month carries that month's
//     name. "Contains" means one of the column's seven local days IS the 1st.
//   • Every other entry is nil.
//
//   CONSEQUENCE, pinned below and accepted: when the 1st falls inside COLUMN 0,
//   that month gets no label at all — column 0 is already spoken for by the
//   window-start month, and the rule for later columns does not reach it. A
//   window opening Sun Dec 28 is headed "Dec" and January is never named.
//   `januaryIsSwallowedWhenItsFirstFallsInsideColumnZero` is that case, stated as
//   a test so it is a decision rather than a surprise.
//
// ── The names ───────────────────────────────────────────────────────────────
//   Three-letter month abbreviations from a `gregorian` calendar formatted with
//   `en_US_POSIX`: Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec. Fixed, not
//   locale-derived. No year, ever.
// ─────────────────────────────────────────────────────────────────────────────

private enum Pinned {
    /// Stated as literals rather than read from the production constants, so the
    /// window cannot be resized and the labels re-blessed in one edit.
    static let windowDays = 112
    static let columns = 16

    /// Indiana over UTC for the same reason the mapping suite chose it: in UTC
    /// the local day and the instant's day always agree, so every zone bug here
    /// would pass. It also carries a real DST rule, which the February window
    /// below crosses.
    static let zone = TimeZone(identifier: "America/Indianapolis")!
    static let utc = TimeZone(identifier: "UTC")!

    // ── Window A: opens mid-month, crosses the spring-forward ───────────────
    //
    /// `2026-02-24T15:00:00Z` — **10:00 on TUESDAY Feb 24 2026** in Indiana.
    static let midFebruary = Date(timeIntervalSince1970: 1_771_945_200)

    /// The 16 columns `midFebruary` implies, transcribed from a calendar one
    /// column at a time. Window start is Sun Feb 22 (Feb 24 is a Tuesday), and
    /// the window's last day is Sat Jun 13.
    ///
    ///    col  0  Feb 22 – Feb 28   ← window start's month
    ///    col  1  Mar  1 – Mar  7   ← holds Mar 1
    ///    col  2  Mar  8 – Mar 14     (the spring-forward is Mar 8 — a window
    ///    col  3  Mar 15 – Mar 21      counted in 7 × 86_400-second steps slides
    ///    col  4  Mar 22 – Mar 28      an hour here and mislabels everything
    ///    col  5  Mar 29 – Apr  4   ← holds Apr 1        below it)
    ///    col  6  Apr  5 – Apr 11
    ///    col  7  Apr 12 – Apr 18
    ///    col  8  Apr 19 – Apr 25
    ///    col  9  Apr 26 – May  2   ← holds May 1
    ///    col 10  May  3 – May  9
    ///    col 11  May 10 – May 16
    ///    col 12  May 17 – May 23
    ///    col 13  May 24 – May 30
    ///    col 14  May 31 – Jun  6   ← holds Jun 1
    ///    col 15  Jun  7 – Jun 13
    ///
    /// Note col 14 and NOT col 15: the column that opens on May 31 is the one
    /// holding June's first, which is the kind of boundary an implementation
    /// keyed on "the column whose FIRST day is in the new month" gets wrong.
    static let midFebruaryLabels: [String?] = [
        "Feb", "Mar", nil, nil, nil, "Apr", nil, nil, nil, "May", nil, nil, nil, nil, "Jun", nil,
    ]

    // ── Window B: opens ON the 1st ──────────────────────────────────────────
    //
    /// `2026-03-03T15:00:00Z` — **10:00 on Tuesday Mar 3 2026** in Indiana. The
    /// window opens Sun Mar 1, so the two rules agree about column 0 and the
    /// question is whether the label appears once or twice.
    static let earlyMarch = Date(timeIntervalSince1970: 1_772_550_000)

    ///    col 0  Mar  1 – Mar  7   ← window start's month, and holds Mar 1
    ///    col 4  Mar 29 – Apr  4   ← holds Apr 1
    ///    col 8  Apr 26 – May  2   ← holds May 1
    ///    col 13 May 31 – Jun  6   ← holds Jun 1
    ///    (last day: Sat Jun 20)
    static let earlyMarchLabels: [String?] = [
        "Mar", nil, nil, nil, "Apr", nil, nil, nil, "May", nil, nil, nil, nil, "Jun", nil, nil,
    ]

    // ── Window C: crosses New Year ──────────────────────────────────────────
    //
    /// `2025-12-30T15:00:00Z` — **10:00 on Tuesday Dec 30 2025** in Indiana.
    static let lateDecember = Date(timeIntervalSince1970: 1_767_106_800)

    ///    col  0  Dec 28 – Jan  3  ← window start's month (Dec) — and Jan 1 is
    ///    col  1  Jan  4 – Jan 10     in here, so January is never named
    ///    col  5  Feb  1 – Feb  7  ← holds Feb 1
    ///    col  9  Mar  1 – Mar  7  ← holds Mar 1
    ///    col 13  Mar 29 – Apr  4  ← holds Apr 1
    ///    (last day: Sat Apr 18 2026)
    static let lateDecemberLabels: [String?] = [
        "Dec", nil, nil, nil, nil, "Feb", nil, nil, nil, "Mar", nil, nil, nil, "Apr", nil, nil,
    ]

    // ── The zone-sensitivity instant ────────────────────────────────────────
    //
    /// `2026-03-01T04:30:00Z` — **23:30 on SATURDAY Feb 28** in Indiana, and
    /// **04:30 on SUNDAY Mar 1** in UTC. Ninety minutes of wall clock apart, two
    /// different weeks: Indiana's window opens Sun Feb 22, UTC's opens Sun Mar 1.
    static let lateSaturdayNight = Date(timeIntervalSince1970: 1_772_339_400)
}

@Suite("Month labels — the grid's column headings, derived from the calendar")
struct GraphMonthLabelTests {

    // MARK: - Shape: one entry per column, indexed by column

    /// The renderer reads `labels[column]`. A compacted array — only the named
    /// columns — would still be a perfectly ordinary `[String]`, and every label
    /// would sit over the wrong column with nothing to say so.
    @Test("there is exactly one entry per week column, named or not")
    func oneEntryPerColumn() {
        // Arrange / Act
        let labels = GraphTranslation.monthLabels(now: Pinned.midFebruary, timeZone: Pinned.zone)

        // Assert
        #expect(labels.count == Pinned.columns)
        #expect(labels.count == Pinned.windowDays / 7)
    }

    /// The count does not depend on where the window opens or how many months it
    /// happens to span. Three windows spanning four and five months alike.
    @Test("every window produces the same number of entries")
    func columnCountIsInvariant() {
        // Arrange
        let instants = [Pinned.midFebruary, Pinned.earlyMarch, Pinned.lateDecember]

        // Act / Assert
        for now in instants {
            let labels = GraphTranslation.monthLabels(now: now, timeZone: Pinned.zone)
            #expect(labels.count == Pinned.columns, "\(now) produced \(labels.count) entries")
        }
    }

    // MARK: - The arithmetic: which column holds a month's first

    /// The worked example, whole. Every column stated — the nils as much as the
    /// names — so a label that drifts one column in either direction fails here
    /// rather than looking like a slightly different but equally plausible grid.
    @Test("a window opening mid-February names Feb, Mar, Apr, May and Jun over the right columns")
    func midFebruaryWindowIsLabelledColumnByColumn() {
        // Arrange / Act
        let labels = GraphTranslation.monthLabels(now: Pinned.midFebruary, timeZone: Pinned.zone)

        // Assert
        #expect(labels == Pinned.midFebruaryLabels)
    }

    /// June's first falls on the column that OPENS on May 31 — an implementation
    /// that labels "the column whose first day is in a new month" puts Jun one
    /// column right, and it is the last column, where it is least likely to be
    /// noticed. Stated separately from the whole-array pin because it is the
    /// specific boundary, and a failure here should read as that boundary.
    @Test("a month whose first falls mid-column labels that column, not the next one")
    func aMonthStartingMidColumnLabelsItsOwnColumn() {
        // Arrange / Act
        let labels = GraphTranslation.monthLabels(now: Pinned.midFebruary, timeZone: Pinned.zone)

        // Assert — May 31 – Jun 6 is column 14; Jun 7 – Jun 13 is column 15.
        #expect(labels[14] == "Jun")
        #expect(labels[15] == nil)
    }

    /// Column 0 is named even when nothing begins there. Feb 22 is not the 1st,
    /// and without this rule the grid's first five columns would carry no scale
    /// at all.
    @Test("column zero carries the window start's month even though no month begins there")
    func columnZeroIsAlwaysNamed() {
        // Arrange / Act
        let labels = GraphTranslation.monthLabels(now: Pinned.midFebruary, timeZone: Pinned.zone)

        // Assert
        #expect(labels[0] == "Feb")
    }

    /// The window that opens exactly ON the 1st: both rules point at column 0 and
    /// they must not fight. One name, in one place, and column 1 stays empty.
    @Test("a window opening on the first names column zero once")
    func openingOnTheFirstNamesColumnZeroOnce() {
        // Arrange / Act
        let labels = GraphTranslation.monthLabels(now: Pinned.earlyMarch, timeZone: Pinned.zone)

        // Assert
        #expect(labels == Pinned.earlyMarchLabels)
    }

    /// The accepted consequence of "column 0 is the window start's month",
    /// written down so it is a decision and not a bug report waiting to happen:
    /// when the 1st lands inside column 0, that month is never named. Dec 28 –
    /// Jan 3 is headed "Dec"; the grid simply never says January.
    @Test("a month whose first falls inside column zero is swallowed by the window start's month")
    func januaryIsSwallowedWhenItsFirstFallsInsideColumnZero() {
        // Arrange / Act — the window opens Sun Dec 28 2025 and Jan 1 is its fifth day.
        let labels = GraphTranslation.monthLabels(now: Pinned.lateDecember, timeZone: Pinned.zone)

        // Assert
        #expect(labels[0] == "Dec")
        #expect(!labels.contains("Jan"))
        #expect(labels == Pinned.lateDecemberLabels)
    }

    /// Crossing the year is otherwise ordinary — Feb, Mar and Apr of the NEXT
    /// year land on their columns, and no label carries a year to disambiguate.
    @Test("a window crossing New Year keeps labelling the months after it")
    func labellingContinuesAcrossTheYearBoundary() {
        // Arrange / Act
        let labels = GraphTranslation.monthLabels(now: Pinned.lateDecember, timeZone: Pinned.zone)

        // Assert
        #expect(labels[5] == "Feb")
        #expect(labels[9] == "Mar")
        #expect(labels[13] == "Apr")
        #expect(labels.compactMap { $0 }.allSatisfy { $0.count == 3 }, "a label carries more than a month name")
    }

    // MARK: - Purity: the clock and the zone are the only inputs

    /// The zone decides which local day `now` is, which decides which week the
    /// window opens in, which decides every label. 23:30 Saturday in Indiana is
    /// 04:30 Sunday in UTC — one instant, two windows, and the UTC reading heads
    /// the grid "Mar" where Indiana heads it "Feb".
    @Test("the injected zone decides the window, and so decides the labels")
    func theZoneDecidesTheLabels() {
        // Arrange / Act — one instant, two zones.
        let indiana = GraphTranslation.monthLabels(now: Pinned.lateSaturdayNight, timeZone: Pinned.zone)
        let utc = GraphTranslation.monthLabels(now: Pinned.lateSaturdayNight, timeZone: Pinned.utc)

        // Assert — Indiana is still in the Feb 22 week; UTC has rolled into Mar 1.
        #expect(indiana[0] == "Feb")
        #expect(indiana[1] == "Mar")
        #expect(utc[0] == "Mar")
        #expect(utc[1] == nil)
    }

    /// No ambient state anywhere: same inputs, same answer, and the same answer
    /// the strip is computed against. A `Date()` or a `TimeZone.current` reached
    /// for inside would make this flap only on the days it matters.
    @Test("the same instant and zone always produce the same labels")
    func labellingIsPure() {
        // Arrange / Act
        let first = GraphTranslation.monthLabels(now: Pinned.midFebruary, timeZone: Pinned.zone)
        let second = GraphTranslation.monthLabels(now: Pinned.midFebruary, timeZone: Pinned.zone)

        // Assert
        #expect(first == second)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// THE JOIN — labels reach the contract on the same row as the cells.
//
// Same priority 1, one layer out. `monthLabels` being right is worthless if the
// column headings and the columns come from different `now`s, or if some courses
// get headings and others do not: two courses in one menu drawn against
// different calendars is a grid that is wrong for at least one of them and looks
// fine for both.
//
// SCOPE: small — `MenuTranslation` over real captured courses, clock injected.
// ═════════════════════════════════════════════════════════════════════════════

private func realMenu(now: Date) throws -> MenuModel {
    MenuTranslation.menu(
        courses: try CrossPackageFixture.realCourses,
        lastFetch: now,
        now: now,
        baseURL: RealData.baseURL,
        assignments: [:],
        timeZone: Pinned.zone
    )
}

@Suite("Month labels reach every course row")
struct MonthLabelWiringTests {

    /// Under always-emit (§2 item 2) every course carries the full window, so
    /// every course carries the full set of headings too. A course whose graph is
    /// drawn without headings would be a grid with no scale, sitting beside
    /// courses that have one.
    @Test("every course row carries one month entry per column of its graph")
    func everyCourseCarriesItsHeadings() throws {
        // Arrange / Act
        let menu = try realMenu(now: Pinned.midFebruary)

        // Assert
        try #require(!menu.courses.isEmpty)
        for course in menu.courses {
            #expect(course.graphMonths.count == course.graph.count / 7, "course \(course.id)")
            #expect(course.graphMonths.count == Pinned.columns, "course \(course.id)")
        }
    }

    /// The headings are the ones this `now` implies — the join uses the same
    /// clock the cells were bucketed with, rather than a second one.
    @Test("the headings a course carries are the ones its window implies")
    func headingsMatchTheWindow() throws {
        // Arrange / Act
        let menu = try realMenu(now: Pinned.midFebruary)

        // Assert
        let course = try #require(menu.courses.first)
        #expect(course.graphMonths == Pinned.midFebruaryLabels)
    }

    /// Every course in one menu is headed identically. They share a `now` and a
    /// zone, so anything else means the join is recomputing per course from
    /// something ambient.
    @Test("every course in one menu is headed by the same months")
    func allCoursesShareOneCalendar() throws {
        // Arrange / Act
        let menu = try realMenu(now: Pinned.lateDecember)

        // Assert
        let headings = Set(menu.courses.map { $0.graphMonths })
        #expect(headings.count == 1, "the menu carries \(headings.count) different calendars")
    }
}
