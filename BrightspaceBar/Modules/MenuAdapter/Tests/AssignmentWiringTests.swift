import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE JOIN — [Assignment] becomes CourseRow.submenu.
//
// Two finished halves meet here and nowhere else. `AssignmentPipeline` knows how
// to fetch, fold, and build a link; `BrightspaceBar` knows how to render a
// submenu. Neither knows the other exists. This file specifies the pure function
// between them.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. CLICK-TARGET CORRECTNESS ACROSS THE JOIN. Course links were a
//      one-dimensional derivation (id → URL). An assignment link is
//      two-dimensional: (courseId, assignmentId) → URL, resolved for many courses
//      in one pass. That is a new failure mode — an assignment row sitting in
//      course A's submenu carrying course B's `ou=`. It fails silently: the page
//      loads, it is a genuine Brightspace page, and nothing announces that it is
//      somebody else's submission folder. Nothing downstream can catch it, because
//      the GUI opens whatever URL it is handed (`MenuAssembler` was deliberately
//      built with no index arithmetic, which pushes the entire burden here).
//
//   2. NO SILENT LOSS OF THE THREE STATES. `neverFetched` / `loaded([])` /
//      `failed(lastKnown:)` are distinct on purpose, and the GUI collapses one
//      distinction on its own: an EMPTY submenu produces no NSMenu at all. So
//      `loaded([])` translating to `[]` would render as "this feature does not
//      exist" rather than "nothing is due", and `failed` translating to `[]` would
//      silently blank a submenu that was showing real assignments a minute ago.
//
// CULLED: cosmetics beyond the pinned format, localization (single-locale app —
// the existing status line already ships English), performance (a handful of
// courses, a handful of assignments each), and any claim about what a hidden
// assignment's page actually renders (unobservable: no reachable course has one).
//
// SCOPE: all Google-small. Pure translation on plain values; `now` and the time
// zone are parameters. Two tests read fixture bytes off disk, but only to obtain
// inputs — the behaviour under test never touches I/O.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly these.
//
// ── MenuTranslation.menu gains two defaulted parameters ─────────────────────
//     assignments: [Int: AssignmentsState] = [:]
//     timeZone: TimeZone = .current
//   Both defaulted, and appended AFTER the existing four, so every one of the 227
//   existing call sites compiles untouched. A course absent from `assignments` is
//   `neverFetched` — which, since slice 5, still yields a submenu ("No
//   assignments"), so the default `[:]` no longer reproduces the pre-assignment
//   output. See the submenu-uniformity note below.
//
//   `timeZone` is a parameter for the same reason `now` is: a pure function may
//   not read ambient state. It is load-bearing rather than pedantic — D2L states
//   deadlines as instants (`2026-03-01T04:59:00.000Z` is 23:59 the PREVIOUS day
//   in Indiana), so formatting in the wrong zone shows the wrong deadline day.
//   `.current` belongs in the composition root; tests always pass it explicitly.
//
// ── AssignmentTranslation.submenu(state:courseId:now:baseURL:timeZone:) ─────
//   Returns the submenu rows for ONE course.
//
//     .neverFetched              →  [.message("No assignments")]
//     .loaded([])                →  [.message("No assignments")]
//     .loaded(visible)           →  [.assignment...]  sorted, no message
//     .loaded(all hidden)        →  [.message("No assignments")]
//     .failed(lastKnown: [])     →  [.message("Couldn't load assignments")]
//     .failed(lastKnown: rows)   →  [.assignment...] + .separator
//                                   + .message("Couldn't refresh — may be out of date")
//
//   `neverFetched` is still NOT a "Loading…" row: assignments are deliberately
//   not persisted, so at launch a course has never been asked about and nothing
//   is necessarily in flight, and "Loading…" would be a claim we cannot support.
//
//   What DID change in slice 5 is that it is no longer `[]`. The old policy — no
//   rows, therefore no NSMenu, therefore a plain directly-clickable course — gave
//   the menu two interaction models for rows that look identical, and which model
//   a row got depended on whether a fetch had happened yet. NewVertical-3 §2.3
//   retires it: every course gets at least `[Open Course Home]` + "No
//   assignments", so hovering any course does the same thing.
//
//   The cost is admitted rather than hidden: `neverFetched` and `loaded([])` now
//   render identically, so the submenu alone no longer distinguishes "not asked
//   yet" from "asked, and there are none". The states stay distinct in the store
//   (`AssignmentStoreTests` pins that), and the graph strip — emitted for every
//   state — is what carries the difference visually. Uniformity of interaction
//   was judged worth more than a distinction the user could not act on.
//
//   The separator appears ONLY when assignment rows precede the note. With no
//   rows it would abut the separator `MenuAssembler` already prepends.
//
// ── isHidden: hidden assignments are EXCLUDED ───────────────────────────────
//   `IsHidden` is D2L's own "not visible to students" flag, and respecting the
//   source of truth beats second-guessing it. The tie-breaker is priority 1: a
//   hidden folder is the case most likely to answer a deep link with an error or
//   an access-denied page, which is the same wrong-destination failure this suite
//   exists to prevent. All four real assignments have `IsHidden: false`, so this
//   costs nothing observable today, and it is one line in a pure function with a
//   test pinning it — reversible deliberately, not by accident.
//
// ── sort order (the GUI renders model order VERBATIM) ───────────────────────
//   1. dated assignments before undated ones
//   2. dated: `dueDate` ascending — soonest deadline first
//   3. undated, and any tie: `name` ascending (plain `<`, not locale-aware)
//   4. final tie-break: `id` ascending
//
//   Dated-first is what a student needs. Undated-last follows from having no
//   deadline to compete with. Today every reachable assignment is undated, so the
//   whole list is name-sorted — stable and sane; when a real term brings due
//   dates, deadlines float to the top without a code change. The `name`/`id`
//   tie-break is not decoration: without a total order, `Dictionary`-derived or
//   network-ordered input would reshuffle the submenu between refreshes and
//   `MenuModel`'s `Equatable` — which the GUI uses to skip rebuilding — would
//   compare unequal on identical data.
//
// ── AssignmentTranslation.dueLabel(_:now:timeZone:) → String? ───────────────
//     nil dueDate        →  nil          (the common case: all four real ones)
//     dueDate <  now     →  "Overdue"
//     dueDate >= now     →  "Due MMM d"  e.g. "Due Mar 1", "Due Feb 28"
//
//   Boundary is inclusive: exactly `now` is not yet overdue, matching the
//   inclusive convention the currentness policy already uses.
//
//   "Overdue" deliberately drops the date — once a deadline has passed, the date
//   is not the actionable part, and the currentness filter means only live
//   courses appear at all.
//
//   No year and no time of day. The month abbreviation must come from a FIXED
//   English table and the day from `Calendar(identifier: .gregorian)` with the
//   supplied `timeZone` — NOT from `DateFormatter`/`Date.FormatStyle`, which read
//   `Locale.current` and would make this function's output depend on ambient
//   state. Day is not zero-padded ("Due Mar 1", never "Due Mar 01").
// ─────────────────────────────────────────────────────────────────────────────

/// Expected values, built independently of the production code. Nothing here
/// calls into `AssignmentTranslation` or `AssignmentLink`, so an implementation
/// bug cannot define its own answer.
private enum Pinned {
    static let baseURL = URL(string: "https://purdue.brightspace.com")!

    static let utc = TimeZone(identifier: "UTC")!
    /// Purdue's own zone. UTC−5 in early March 2026 (DST begins March 8), which is
    /// what makes the off-by-one-day deadline bug observable.
    static let indiana = TimeZone(identifier: "America/Indiana/Indianapolis")!

    static let noAssignments = "No assignments"
    static let loadFailed = "Couldn't load assignments"
    static let refreshFailed = "Couldn't refresh — may be out of date"

    /// URLs in the exact shape experiment 7 navigated in a real browser (each
    /// rendered a page naming its own folder). The two courses that carried
    /// those assignments are the undated shells, HIDDEN since the 2026-08-24
    /// user decision — so the end-to-end tests below host the same real
    /// assignment bytes on CURRENT courses, and these literals pin the same
    /// verified template with the host course's `ou=`. Written out in full
    /// rather than interpolated, so editing the template cannot silently
    /// rewrite the expectation alongside the code.
    static let citiURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445296&grpid=0&ou=1360027"
    static let purcURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=445297&grpid=0&ou=1360027"
    static let ideationURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=529524&grpid=0&ou=1360027"
    static let untitledURL =
        "https://purdue.brightspace.com/d2l/lms/dropbox/user/folder_submit_files.d2l?db=648911&grpid=0&ou=1360020"
}

/// The two courses that actually have assignments, and their real contents —
/// transcribed by hand from experiment 7's live capture.
private enum RealAssignments {
    static let scholarlyID = 440_703
    static let scholarlyName = "Scholarly Project Milestones"
    static let citiID = 445_296
    static let citiName = "Upload your CITI Certificate to Complete Module 2"
    static let purcID = 445_297
    static let purcName = "Report on your PURC Experience."
    static let ideationID = 529_524
    static let ideationName = "Getting Started on Scholarly Project Ideation"

    static let civicsID = 412_690
    static let untitledID = 648_911
    static let untitledName = "Untitled"

    /// Current HOSTS for the real assignment bytes. The two shells above are
    /// hidden since the 2026-08-24 user decision (undated → no menu space, no
    /// fetches), so the end-to-end tests re-home the same genuine dropbox bytes
    /// on dated Fall 2025 courses that ARE visible at `midFall2025`. Two hosts,
    /// so the cross-course `ou=` guarantee is still exercised.
    static let hostAID = 1_360_027  // Fall 2025 CS 25100-LEC - Merge
    static let hostAName = "Fall 2025 CS 25100-LEC - Merge"
    static let hostBID = 1_360_020  // Fall 2025 CS 25000 - Merge

    /// Name-ascending, which is the pinned order for an all-undated course.
    /// Independently sorted here by reading the three names, not by calling the
    /// production comparator.
    static let scholarlyIDsInMenuOrder = [ideationID, purcID, citiID]
}

/// Instants computed with `python3`, independent of any Swift date arithmetic.
private enum Instant {
    /// `2026-02-20T00:00:00Z` — before every due date below.
    static let feb20 = Date(timeIntervalSince1970: 1_771_545_600)
    /// `2026-03-01T04:59:00Z`. A REAL-shaped D2L deadline: 23:59 on Feb 28 in
    /// Indiana. Formats as "Mar 1" in UTC and "Feb 28" in Indianapolis.
    static let mar1Utc = Date(timeIntervalSince1970: 1_772_341_140)
    /// `2026-09-15T23:59:00Z` — "Sep 15" in both zones.
    static let sep15 = Date(timeIntervalSince1970: 1_789_516_740)
    /// `2026-11-09T00:00:00Z` — after every due date above.
    static let nov9 = Date(timeIntervalSince1970: 1_794_182_400)
}

// MARK: - Local helpers

/// The real `dropbox/folders` payloads, reached across the module boundary.
///
/// They belong to `AssignmentPipeline`'s test target, which this one cannot
/// import, so they are located by walking up from `#filePath` — the same
/// technique `CrossPackageFixture` already uses for the enrollment payload.
private enum AssignmentFixture {
    /// `<package root>/Modules/AssignmentPipeline/Tests/Fixtures/`
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Modules/MenuAdapter/Tests
            .deletingLastPathComponent()   // Modules/MenuAdapter
            .deletingLastPathComponent()   // Modules
            .appending(path: "AssignmentPipeline")
            .appending(path: "Tests")
            .appending(path: "Fixtures")
            .standardizedFileURL
    }

    static func bytes(_ name: String) throws -> Data {
        try Data(contentsOf: self.directory.appending(path: name))
    }

    /// Parsed with the REAL parser, so the chain is genuinely
    /// bytes → parser → store → translation and not hand-built data in costume.
    static func assignments(_ name: String, courseId: Int) throws -> [Assignment] {
        try AssignmentParser.parse(self.bytes(name), courseId: courseId)
    }

    static var scholarly: [Assignment] {
        get throws { try self.assignments("dropbox-folders-440703.json", courseId: RealAssignments.scholarlyID) }
    }

    static var civics: [Assignment] {
        get throws { try self.assignments("dropbox-folders-412690.json", courseId: RealAssignments.civicsID) }
    }

    /// The same real bytes, homed on the CURRENT courses the E2E tests render —
    /// the shells that originally carried them are hidden since 2026-08-24.
    static var scholarlyOnHostA: [Assignment] {
        get throws { try self.assignments("dropbox-folders-440703.json", courseId: RealAssignments.hostAID) }
    }

    static var civicsOnHostB: [Assignment] {
        get throws { try self.assignments("dropbox-folders-412690.json", courseId: RealAssignments.hostBID) }
    }
}

/// An `AssignmentSource` scripted per course. `FakeAssignmentSource` lives in
/// `AssignmentPipeline`'s test target, which is a separate module; this is the
/// minimum replacement needed to drive `AssignmentFetcher` for real.
private actor ScriptedSource: AssignmentSource {
    private let byCourse: [Int: Result<[Assignment], CourseSourceError>]

    init(_ byCourse: [Int: Result<[Assignment], CourseSourceError>]) {
        self.byCourse = byCourse
    }

    func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        switch self.byCourse[courseId] {
        case .success(let assignments): return assignments
        case .failure(let error): throw error
        case nil: return []
        }
    }
}

private func assignment(
    id: Int,
    courseId: Int = RealAssignments.scholarlyID,
    name: String = "An Assignment",
    dueDate: Date? = nil,
    isHidden: Bool = false,
    groupTypeId: Int? = nil
) -> Assignment {
    Assignment(
        id: id, courseId: courseId, name: name,
        dueDate: dueDate, isHidden: isHidden, groupTypeId: groupTypeId
    )
}

/// A course with a wide-open Access window, so it is CURRENT — and therefore
/// visible — at any test `now`. An undated shell would be hidden entirely under
/// the 2026-08-24 policy, so it can no longer host assignments in these tests.
private func currentCourse(id: Int, name: String = "A Course") -> Course {
    Course(
        id: id, name: name, code: "shell_\(id)", role: "Learner", isActive: true,
        homeUrl: nil,
        startDate: "2000-01-01T00:00:00.000Z", endDate: "2999-01-01T00:00:00.000Z"
    )
}

private extension MenuModel {
    func course(id: Int) -> CourseRow? { self.courses.first { $0.id == id } }
}

private func messages(_ rows: [MenuRow]) -> [String] {
    rows.compactMap { if case .message(let text) = $0 { text } else { nil } }
}

// MARK: - dueLabel

@Suite("dueLabel — the pre-formatted deadline the GUI renders verbatim")
struct AssignmentDueLabelTests {

    @Test("no due date yields nil, never a placeholder or an epoch date")
    func nilDueDateYieldsNil() {
        // Arrange / Act — the state of all four reachable assignments.
        let label = AssignmentTranslation.dueLabel(nil, now: Instant.feb20, timeZone: Pinned.utc)

        // Assert
        #expect(label == nil)
    }

    @Test("a future due date reads as a month and day, with no year and no time")
    func futureDueDateIsFormatted() {
        // Arrange / Act
        let label = AssignmentTranslation.dueLabel(
            Instant.sep15, now: Instant.feb20, timeZone: Pinned.utc
        )

        // Assert — no "2026", no "23:59", no zero-padding.
        #expect(label == "Due Sep 15")
    }

    @Test("a past due date reads as Overdue")
    func pastDueDateIsOverdue() {
        // Arrange / Act — now is 2026-11-09, the deadline was 2026-09-15.
        let label = AssignmentTranslation.dueLabel(
            Instant.sep15, now: Instant.nov9, timeZone: Pinned.utc
        )

        // Assert
        #expect(label == "Overdue")
    }

    @Test("a due date exactly equal to now is not yet overdue")
    func theOverdueBoundaryIsInclusive() {
        // Arrange / Act — inclusive, matching the currentness policy's convention.
        // An assignment does not become overdue at the instant it falls due.
        let label = AssignmentTranslation.dueLabel(
            Instant.sep15, now: Instant.sep15, timeZone: Pinned.utc
        )

        // Assert
        #expect(label == "Due Sep 15")
    }

    @Test("the time zone decides the calendar day, so a late-night deadline is not off by one")
    func timeZoneDecidesTheDay() {
        // Arrange — 2026-03-01T04:59:00Z is the REAL shape of a D2L deadline:
        // 23:59 on February 28 in Indiana. Formatting in UTC would tell a student
        // their work is due March 1 when Brightspace will close it on February 28.
        let due = Instant.mar1Utc

        // Act
        let inUTC = AssignmentTranslation.dueLabel(due, now: Instant.feb20, timeZone: Pinned.utc)
        let inIndiana = AssignmentTranslation.dueLabel(due, now: Instant.feb20, timeZone: Pinned.indiana)

        // Assert — the whole reason `timeZone` is a parameter.
        #expect(inUTC == "Due Mar 1")
        #expect(inIndiana == "Due Feb 28")
    }

    @Test("the day is not zero-padded")
    func singleDigitDaysAreNotPadded() {
        // Arrange — 2026-03-05T12:00:00Z. Deliberately in the FUTURE relative to
        // `feb20`: a past single-digit date would render "Overdue" per this file's
        // own policy (see `pastDueDateIsOverdue`), so it could never exercise day
        // formatting at all. Corrected by the orchestrator; the claim — that a
        // single-digit day is not zero-padded — is unchanged.
        let mar5 = Date(timeIntervalSince1970: 1_772_712_000)

        // Act
        let label = AssignmentTranslation.dueLabel(mar5, now: Instant.feb20, timeZone: Pinned.utc)

        // Assert — guards against a formatter emitting "Mar 05".
        #expect(label == "Due Mar 5")
    }
}

// MARK: - The three states

@Suite("submenu — the three assignment states stay distinguishable")
struct AssignmentSubmenuStateTests {

    private func submenu(_ state: AssignmentsState, courseId: Int = RealAssignments.scholarlyID) -> [MenuRow] {
        AssignmentTranslation.submenu(
            state: state, courseId: courseId,
            now: Instant.feb20, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )
    }

    @Test("neverFetched still yields a submenu, so every course hovers the same way")
    func neverFetchedYieldsTheEmptyMessage() {
        // Arrange / Act — assignments are not persisted, so this is every course's
        // state at launch. It must NOT be `[]`: an empty list makes the GUI attach
        // no NSMenu, which leaves the menu with two interaction models for rows
        // that look identical (NewVertical-3 §2.3).
        let rows = self.submenu(.neverFetched)

        // Assert
        #expect(rows == [.message(Pinned.noAssignments)])
    }

    @Test("neverFetched and a successful empty fetch are deliberately indistinguishable")
    func neverFetchedRendersAsLoadedEmpty() {
        // Arrange / Act — the collapse slice 5 accepts on purpose. "Not asked yet"
        // and "asked, and there are none" are still distinct in the store; they are
        // no longer distinct in the submenu, because the user cannot act on the
        // difference and uniform hover behaviour is worth more.
        let unfetched = self.submenu(.neverFetched)

        // Assert
        #expect(unfetched == self.submenu(.loaded([])))
    }

    @Test("a successful empty fetch says so, rather than producing no submenu")
    func loadedEmptyYieldsTheEmptyMessage() {
        // Arrange / Act — `[]` here would make the GUI attach no submenu at all,
        // which reads as "this feature does not exist" instead of "nothing is due".
        let rows = self.submenu(.loaded([]))

        // Assert
        #expect(rows == [.message(Pinned.noAssignments)])
    }

    @Test("a first failure with nothing known says loading failed")
    func failedWithNothingKnownSaysSo() {
        // Arrange / Act — a dead session on the very first fetch. There is nothing
        // to show, but staying silent would be indistinguishable from a course
        // that genuinely has no assignments.
        let rows = self.submenu(.failed(lastKnown: [], error: .sessionExpired))

        // Assert
        #expect(rows == [.message(Pinned.loadFailed)])
    }

    @Test("a failure never blanks a submenu that had assignments")
    func failedPreservesKnownAssignments() throws {
        // Arrange — the normal case for this tenant: the session dies within
        // hours, so a refresh failing over data we already hold is routine.
        let known = try AssignmentFixture.scholarly

        // Act
        let rows = self.submenu(.failed(lastKnown: known, error: .sessionExpired))

        // Assert — every assignment still rendered.
        #expect(rows.assignments.count == 3)
        #expect(Set(rows.assignments.map(\.id)) == [
            RealAssignments.citiID, RealAssignments.purcID, RealAssignments.ideationID,
        ])
    }

    @Test("a failure over known assignments adds a staleness note after them")
    func failedAppendsTheStalenessNote() throws {
        // Arrange
        let known = try AssignmentFixture.scholarly

        // Act
        let rows = self.submenu(.failed(lastKnown: known, error: .sessionExpired))

        // Assert — assignments first (the useful content), caveat last, with a
        // separator between. Mirrors the top-level menu's rows-then-status shape.
        #expect(messages(rows) == [Pinned.refreshFailed])
        #expect(rows.count == 5)
        #expect(rows[3] == .separator)
        #expect(rows[4] == .message(Pinned.refreshFailed))
    }

    @Test("a failure with nothing known carries no leading separator")
    func failedWithNothingKnownHasNoSeparator() {
        // Arrange / Act — `MenuAssembler` already prepends a separator after the
        // course-home row, so one here would double up on a submenu whose only
        // content is the note.
        let rows = self.submenu(.failed(lastKnown: [], error: .transport("offline")))

        // Assert
        #expect(!rows.contains(.separator))
    }

    @Test("a loaded course carries no note of any kind")
    func loadedCarriesNoNote() throws {
        // Arrange
        let loaded = try AssignmentFixture.scholarly

        // Act
        let rows = self.submenu(.loaded(loaded))

        // Assert — nothing to apologise for, so nothing is said.
        #expect(messages(rows).isEmpty)
        #expect(!rows.contains(.separator))
    }
}

// MARK: - Ordering and the hidden policy

@Suite("submenu — ordering and visibility policy")
struct AssignmentSubmenuOrderTests {

    private func rows(_ assignments: [Assignment], now: Date = Instant.feb20) -> [MenuRow] {
        AssignmentTranslation.submenu(
            state: .loaded(assignments), courseId: RealAssignments.scholarlyID,
            now: now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )
    }

    @Test("dated assignments come before undated ones")
    func datedBeforeUndated() {
        // Arrange — deliberately handed over undated-first, so a passing result
        // cannot be an artifact of input order.
        let input = [
            assignment(id: 1, name: "Zeta", dueDate: nil),
            assignment(id: 2, name: "Alpha", dueDate: Instant.sep15),
        ]

        // Act
        let ids = self.rows(input).assignments.map(\.id)

        // Assert
        #expect(ids == [2, 1])
    }

    @Test("dated assignments are ordered soonest deadline first")
    func datedAreAscendingByDueDate() {
        // Arrange — later date first on input.
        let input = [
            assignment(id: 1, name: "Later", dueDate: Instant.sep15),
            assignment(id: 2, name: "Sooner", dueDate: Instant.mar1Utc),
        ]

        // Act
        let ids = self.rows(input).assignments.map(\.id)

        // Assert
        #expect(ids == [2, 1])
    }

    @Test("undated assignments are ordered by name")
    func undatedAreAlphabetical() {
        // Arrange — the case that actually ships today: every reachable
        // assignment is undated, so the whole list is name-sorted.
        let input = [
            assignment(id: 1, name: "Charlie"),
            assignment(id: 2, name: "Alpha"),
            assignment(id: 3, name: "Bravo"),
        ]

        // Act
        let ids = self.rows(input).assignments.map(\.id)

        // Assert
        #expect(ids == [2, 3, 1])
    }

    @Test("assignments sharing a due date fall back to name, then id")
    func tiesResolveDeterministically() {
        // Arrange — without a total order, network- or dictionary-ordered input
        // would reshuffle the submenu between refreshes and break the GUI's
        // Equatable skip-rebuild on identical data.
        let input = [
            assignment(id: 9, name: "Same", dueDate: Instant.sep15),
            assignment(id: 4, name: "Same", dueDate: Instant.sep15),
            assignment(id: 7, name: "Earlier Name", dueDate: Instant.sep15),
        ]

        // Act
        let ids = self.rows(input).assignments.map(\.id)

        // Assert
        #expect(ids == [7, 4, 9])
    }

    @Test("a hidden assignment is not rendered")
    func hiddenAssignmentsAreExcluded() {
        // Arrange — `IsHidden` is D2L's own "not for students" flag; a hidden
        // folder is also the case most likely to answer its deep link with an
        // access-denied page.
        let input = [
            assignment(id: 1, name: "Visible"),
            assignment(id: 2, name: "Concealed", isHidden: true),
        ]

        // Act
        let ids = self.rows(input).assignments.map(\.id)

        // Assert
        #expect(ids == [1])
    }

    @Test("a course whose only assignments are hidden says No assignments")
    func allHiddenStillYieldsTheEmptyMessage() {
        // Arrange — filtering must not produce `[]`, which the GUI reads as
        // "no submenu" rather than "nothing to show".
        let input = [assignment(id: 1, name: "Concealed", isHidden: true)]

        // Act
        let rows = self.rows(input)

        // Assert
        #expect(rows == [.message(Pinned.noAssignments)])
    }

    @Test("an assignment's subtitle is the formatted due date and nothing else")
    func subtitleCarriesTheFormattedDate() throws {
        // Arrange
        let input = [assignment(id: 1, name: "Homework", dueDate: Instant.sep15)]

        // Act
        let row = try #require(self.rows(input).assignments.first)

        // Assert — the GUI renders `subtitle` verbatim, so the formatting must
        // already be finished here.
        #expect(row.title == "Homework")
        #expect(row.subtitle == "Due Sep 15")
        #expect(row.dueDate == Instant.sep15)
    }

    @Test("an undated assignment carries a nil subtitle, not an empty string")
    func undatedSubtitleIsNil() throws {
        // Arrange / Act — the common case. An empty string would render as a
        // trailing separator in the GUI's "title — subtitle" format.
        let row = try #require(self.rows([assignment(id: 1, name: "Untitled")]).assignments.first)

        // Assert
        #expect(row.subtitle == nil)
        #expect(row.dueDate == nil)
    }
}

// MARK: - The full vertical

@Suite("The join — real bytes through parser, store, and translation into a menu")
struct AssignmentWiringEndToEndTests {

    /// The 7 current courses visible at `midFall2025`, per the 2026-08-24
    /// currentness policy (undated shells hidden).
    private func realMenu(
        assignments: [Int: AssignmentsState],
        now: Date = RealData.midFall2025
    ) throws -> MenuModel {
        MenuTranslation.menu(
            courses: try CrossPackageFixture.realCourses,
            lastFetch: now,
            now: now,
            baseURL: Pinned.baseURL,
            assignments: assignments,
            timeZone: Pinned.utc
        )
    }

    @Test("the headline path: real assignments reach a current course's submenu with the verified URL shape")
    func theFullChainPopulatesASubmenu() async throws {
        // Arrange — genuine enrollment bytes through the genuine `EnrollmentParser`,
        // genuine dropbox bytes through the genuine `AssignmentParser`, folded by
        // the genuine `AssignmentStore`. The bytes are re-homed on a CURRENT
        // course: the shell that carried them is hidden since the 2026-08-24
        // user decision, and hidden courses get no submenu to populate.
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        _ = await store.apply(
            courseId: RealAssignments.hostAID,
            result: .success(try AssignmentFixture.scholarlyOnHostA)
        )
        let state = await store.state(for: RealAssignments.hostAID)

        // Act
        let model = try self.realMenu(assignments: [RealAssignments.hostAID: state])

        // Assert — the course renders, and its submenu carries all three
        // assignments with the exact names and the verified URL template.
        let course = try #require(model.course(id: RealAssignments.hostAID))
        #expect(course.title == RealAssignments.hostAName)

        let rows = course.submenu.assignments
        try #require(rows.count == 3)
        #expect(rows.map(\.id) == RealAssignments.scholarlyIDsInMenuOrder)

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[RealAssignments.citiID]?.title == RealAssignments.citiName)
        #expect(byID[RealAssignments.citiID]?.url.absoluteString == Pinned.citiURL)
        #expect(byID[RealAssignments.purcID]?.title == RealAssignments.purcName)
        #expect(byID[RealAssignments.purcID]?.url.absoluteString == Pinned.purcURL)
        #expect(byID[RealAssignments.ideationID]?.title == RealAssignments.ideationName)
        #expect(byID[RealAssignments.ideationID]?.url.absoluteString == Pinned.ideationURL)
    }

    @Test("every assignment carries its OWN course in ou, never a neighbour's")
    func assignmentsNeverCrossCourses() async throws {
        // Arrange — PRIORITY 1, and the failure mode the join newly makes
        // possible. Two visible current courses hold assignments at once, so a
        // shared or last-wins course id produces a valid Brightspace URL
        // pointing at somebody else's submission folder.
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        _ = await store.apply(
            courseId: RealAssignments.hostAID, result: .success(try AssignmentFixture.scholarlyOnHostA)
        )
        _ = await store.apply(
            courseId: RealAssignments.hostBID, result: .success(try AssignmentFixture.civicsOnHostB)
        )
        let states = [
            RealAssignments.hostAID: await store.state(for: RealAssignments.hostAID),
            RealAssignments.hostBID: await store.state(for: RealAssignments.hostBID),
        ]

        // Act
        let model = try self.realMenu(assignments: states)

        // Assert — checked per course, so a failure names which one leaked.
        for courseId in [RealAssignments.hostAID, RealAssignments.hostBID] {
            let course = try #require(model.course(id: courseId))
            let rows = course.submenu.assignments
            try #require(!rows.isEmpty, "course \(courseId) rendered no assignments")
            for row in rows {
                #expect(
                    row.url.absoluteString.contains("ou=\(courseId)"),
                    "assignment \(row.id) in course \(courseId) points at another course"
                )
                #expect(
                    row.url.absoluteString.contains("db=\(row.id)"),
                    "assignment \(row.id) does not point at itself"
                )
            }
        }
    }

    @Test("the second host gets exactly the URL template experiment 7 verified")
    func theOtherCourseGetsItsVerifiedURL() async throws {
        // Arrange — the second host course, asserted against a full literal so
        // a systematic id shift cannot pass. (The civics shell that originally
        // carried this assignment is hidden since 2026-08-24 — pinned below.)
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        _ = await store.apply(
            courseId: RealAssignments.hostBID, result: .success(try AssignmentFixture.civicsOnHostB)
        )
        let state = await store.state(for: RealAssignments.hostBID)

        // Act
        let model = try self.realMenu(assignments: [RealAssignments.hostBID: state])

        // Assert
        let course = try #require(model.course(id: RealAssignments.hostBID))
        let row = try #require(course.submenu.assignments.first)
        #expect(row.title == RealAssignments.untitledName)
        #expect(row.url.absoluteString == Pinned.untitledURL)
    }

    @Test("the hidden shells never render, even when assignment state exists for them")
    func hiddenShellsStayHiddenDespiteAssignmentState() async throws {
        // Arrange — the negative of the old headline path. User decision
        // 2026-08-24: the undated shells (Civics, Scholarly Project) are hidden
        // everywhere, so even a store that holds their REAL assignments must
        // not conjure their rows back into the menu.
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        _ = await store.apply(
            courseId: RealAssignments.scholarlyID, result: .success(try AssignmentFixture.scholarly)
        )
        _ = await store.apply(
            courseId: RealAssignments.civicsID, result: .success(try AssignmentFixture.civics)
        )
        let states = [
            RealAssignments.scholarlyID: await store.state(for: RealAssignments.scholarlyID),
            RealAssignments.civicsID: await store.state(for: RealAssignments.civicsID),
        ]

        // Act
        let model = try self.realMenu(assignments: states)

        // Assert — the visible set excludes both shells, and none of their
        // assignments appear anywhere in the model.
        #expect(model.course(id: RealAssignments.scholarlyID) == nil)
        #expect(model.course(id: RealAssignments.civicsID) == nil)
        #expect(model.courses.allSatisfy { $0.submenu.assignments.isEmpty })
    }

    @Test("the fetcher's fan-out reaches the menu, and one failing course does not empty another")
    func fanOutThroughTheFetcherReachesTheMenu() async throws {
        // Arrange — the widest chain in the suite: `AssignmentFetcher` over two
        // courses, one succeeding and one failing, then translation. This is the
        // real shape of a partial failure on this tenant.
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        let fetcher = AssignmentFetcher(
            source: ScriptedSource([
                RealAssignments.hostAID: .success(try AssignmentFixture.scholarlyOnHostA),
                RealAssignments.hostBID: .failure(.sessionExpired),
            ]),
            store: store
        )
        let courses = [
            currentCourse(id: RealAssignments.hostAID),
            currentCourse(id: RealAssignments.hostBID),
        ]

        // Act
        _ = await fetcher.refresh(courses: courses)
        let model = MenuTranslation.menu(
            courses: courses, lastFetch: Instant.feb20, now: Instant.feb20,
            baseURL: Pinned.baseURL,
            assignments: [
                RealAssignments.hostAID: await store.state(for: RealAssignments.hostAID),
                RealAssignments.hostBID: await store.state(for: RealAssignments.hostBID),
            ],
            timeZone: Pinned.utc
        )

        // Assert — the succeeding course is fully populated…
        let succeeded = try #require(model.course(id: RealAssignments.hostAID))
        #expect(succeeded.submenu.assignments.count == 3)
        // …and the failing one says so rather than silently claiming emptiness.
        let failed = try #require(model.course(id: RealAssignments.hostBID))
        #expect(messages(failed.submenu) == [Pinned.loadFailed])
    }

    @Test("with no assignment state at all, every course still gets a submenu")
    func absentStateStillYieldsASubmenuEverywhere() throws {
        // Arrange / Act — the launch shape: nothing fetched yet, so every course is
        // `neverFetched`. The old guarantee here was "no entry means no submenu";
        // slice 5 retires it, because that was what made a course's interaction
        // model depend on whether a fetch had happened.
        let model = try self.realMenu(assignments: [:])

        // Assert — the currentness expectations are unchanged, and no course is
        // left as a bare row.
        #expect(Set(model.courses.map(\.id)) == RealData.visibleIDsAtMidFall2025)
        #expect(model.courses.allSatisfy { $0.submenu == [.message(Pinned.noAssignments)] })
    }

    @Test("supplying assignments adds rows only to the courses that have them")
    func onlyTheNamedCourseGainsAssignmentRows() async throws {
        // Arrange
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        _ = await store.apply(
            courseId: RealAssignments.hostAID, result: .success(try AssignmentFixture.scholarlyOnHostA)
        )
        let state = await store.state(for: RealAssignments.hostAID)

        // Act
        let model = try self.realMenu(assignments: [RealAssignments.hostAID: state])

        // Assert — seven courses visible, all with submenus, exactly one of which
        // holds real assignment rows. The others say "No assignments" rather than
        // vanishing as a submenu.
        #expect(Set(model.courses.map(\.id)) == RealData.visibleIDsAtMidFall2025)
        #expect(model.courses.allSatisfy { !$0.submenu.isEmpty })
        let withAssignments = model.courses.filter { !$0.submenu.assignments.isEmpty }.map(\.id)
        #expect(withAssignments == [RealAssignments.hostAID])
    }

    @Test("translation is deterministic even when the assignments arrive shuffled")
    func shuffledAssignmentsYieldTheSameModel() async throws {
        // Arrange — `MenuModel`'s `Equatable` is what lets the GUI skip
        // rebuilding an unchanged menu, so an order-dependent submenu would make
        // identical data compare unequal and rebuild the menu on every open.
        let real = try AssignmentFixture.scholarlyOnHostA
        try #require(real.count == 3)

        // Act
        let a = try self.realMenu(assignments: [RealAssignments.hostAID: .loaded(real)])
        let b = try self.realMenu(assignments: [RealAssignments.hostAID: .loaded(Array(real.reversed()))])

        // Assert — the count guard is load-bearing: two empty models are
        // trivially equal, so without it this passes against a translation that
        // renders nothing.
        try #require(a.course(id: RealAssignments.hostAID)?.submenu.assignments.count == 3)
        #expect(a == b, "submenu order depends on input order")
    }

    @Test("assignments appear only inside submenus, never at the top level")
    func assignmentsDoNotLeakToTheTopLevel() async throws {
        // Arrange — `.assignment` is documented as a submenu-only row. A leak
        // would render an assignment as a sibling of the courses.
        let store = AssignmentStore(clock: ManualClock(RealData.midFall2025))
        _ = await store.apply(
            courseId: RealAssignments.hostAID, result: .success(try AssignmentFixture.scholarlyOnHostA)
        )

        // Act
        let model = try self.realMenu(assignments: [
            RealAssignments.hostAID: await store.state(for: RealAssignments.hostAID),
        ])

        // Assert
        #expect(model.rows.assignments.isEmpty)
    }
}
