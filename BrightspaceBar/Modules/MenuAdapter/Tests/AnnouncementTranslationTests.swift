import Foundation
import Testing

import AssignmentPipeline
import CourseMenu
import CoursePipeline
import MenuAdapter

// ═════════════════════════════════════════════════════════════════════════════
// THE SECOND JOIN — [Announcement] becomes the tail of CourseRow.submenu.
//
// The assignments half of a submenu answers "what do I owe?". This half answers
// "what did they say?", and it is a fundamentally different kind of list: work
// items are a SET (all of them, ordered by deadline), announcements are a
// WINDOW (the recent few, newest first). Everything below follows from that.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE WINDOW IS THE WHOLE FEATURE. Which announcements qualify, in which
//      order, and how many — that is all this function decides, and every way of
//      deciding wrong is silent. A cutoff off by a second buries a post that
//      arrived this morning; a cutoff that never fires shows a syllabus notice
//      from last term as though it were news; a missing future-date guard
//      announces a post D2L has not published yet, which the student cannot open;
//      and an unstable order reshuffles the menu between refreshes, which also
//      breaks `MenuModel`'s `Equatable` skip-rebuild on identical data.
//
//   2. THE SECTION MUST NOT DAMAGE THE SUBMENU IT JOINS. This is a SUFFIX
//      appended to a shipped feature, so it can only be additive. Three failures
//      of that kind: an empty section (a separator and a header leading nothing,
//      in every submenu that has no recent posts), a second staleness note (the
//      assignments half already carries one, and two apologies in one submenu
//      read as two separate faults), and a row carrying a neighbouring course's
//      `ou=` — the same silent cross-wiring `AssignmentWiringTests` exists to
//      prevent, made possible again by a second per-course fan-out.
//
// CULLED: announcement BODY text (the daemon does not fetch it and the row has
// nowhere to put it), per-item deep links (D2L offers none worth trusting across
// tenants — every row goes to the course's announcements page by design), read
// versus unread state (unavailable from the payload), and localization (the app
// ships single-locale English, as the status line already does).
//
// SCOPE: all Google-small. Pure translation over plain values; `now` and the time
// zone are parameters, so nothing here reads a clock, a locale, or the world.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly these.
//
// ── AnnouncementTranslation.section(state:courseId:now:baseURL:timeZone:) ────
//   Returns the announcements SECTION appended to ONE course's submenu, AFTER
//   whatever `AssignmentTranslation.submenu` produced.
//
//     no qualifying announcements  →  []
//     one or more                  →  [.separator, .sectionHeader("Announcements")]
//                                     + rows
//
//   `[]` and not a "No announcements" line, which is the opposite of the
//   assignments half's rule and deliberately so. That line exists there because a
//   submenu with no rows at all gets no NSMenu and therefore a different
//   interaction model; here the assignments half has already guaranteed the
//   submenu exists, so silence costs nothing and a permanent empty section in
//   every quiet course costs two rows of noise.
//
// ── Qualifying: dated, within the last 30 days, not in the future ───────────
//     date == nil                  →  excluded
//     date <  now − 30 days        →  excluded
//     date >= now − 30 days        →  included   (boundary INCLUSIVE)
//     date <= now                  →  included   (boundary INCLUSIVE)
//     date >  now                  →  excluded
//
//   Undated items are excluded because a cutoff cannot be applied to a date that
//   does not exist — including them would put an item of unknown age at an
//   arbitrary position in a list whose entire ordering is by age. Future dates are
//   excluded because a `StartDate` ahead of now is a post D2L has SCHEDULED and
//   not yet published: announcing it early is announcing something the student
//   cannot go and read.
//
//   Both boundaries are inclusive, matching the convention `dueLabel` and the
//   currentness policy already use.
//
// ── Order and cap ───────────────────────────────────────────────────────────
//   Newest first, then `id` ascending, capped at 5.
//
//   The `id` tie-break is not decoration. Swift's sort is not stable, so two posts
//   sharing an instant — routine when a department posts a batch — would otherwise
//   swap places between refreshes AND change WHICH five survive the cap, making
//   identical data compare unequal and rebuilding the menu on every timer tick.
//
// ── Rows ────────────────────────────────────────────────────────────────────
//   title    │ verbatim
//   subtitle │ the absolute posting date, "MMM d" — e.g. "Aug 10", never padded
//   date     │ the raw instant, carried alongside the rendered form
//   url      │ AnnouncementLink.url(courseId:baseURL:) for EVERY row, derived
//             from the courseId PARAMETER and never from `Announcement.courseId`
//
//   An absolute date rather than "3 days ago": a relative string baked at
//   model-build time is stale the moment the menu is opened later, which is the
//   exact bug experiment 18 removed from the status row. The date does not move,
//   so the row does not go stale.
//
//   The month abbreviation must come from a FIXED English table and the day from
//   `Calendar(identifier: .gregorian)` in the supplied `timeZone` — NOT from
//   `DateFormatter`/`Date.FormatStyle`, which read `Locale.current` and would make
//   this pure function's output depend on the machine it runs on.
//
// ── States ──────────────────────────────────────────────────────────────────
//     .neverFetched                 →  []
//     .loaded([])                   →  []
//     .loaded(all stale/undated)    →  []
//     .loaded(qualifying)           →  the section
//     .failed(lastKnown: [])        →  []
//     .failed(lastKnown: qualifying) →  the section, SILENTLY — no note
//
//   No staleness note here, on purpose: `AssignmentTranslation` already appends
//   one to the same submenu when its own fetch failed, and the two fetches fail
//   together (one dead session, both routes). Two notes in one submenu describe
//   one fault twice.
//
// ── MenuTranslation.menu gains `announcements: [Int: AnnouncementsState] = [:]`
//   Defaulted, so every existing call site compiles untouched and produces
//   byte-identical output — a course absent from the map is `neverFetched`, which
//   contributes no rows at all.
// ─────────────────────────────────────────────────────────────────────────────

/// Expected values, built independently of the production code. Nothing here
/// calls into `AnnouncementTranslation` or `AnnouncementLink`, so an
/// implementation bug cannot define its own answer.
private enum Pinned {
    static let baseURL = URL(string: "https://purdue.brightspace.com")!

    static let utc = TimeZone(identifier: "UTC")!
    /// Purdue's own zone. UTC−4 in August, which is what makes an after-dinner
    /// post that lands on the next UTC day observable.
    static let indiana = TimeZone(identifier: "America/Indiana/Indianapolis")!

    static let header = "Announcements"
    static let cap = 5

    /// The announcements page for a course, written out in full rather than
    /// interpolated from a template, so editing the builder cannot silently
    /// rewrite the expectation alongside the code.
    static let scholarlyURL =
        "https://purdue.brightspace.com/d2l/lms/news/main.d2l?ou=440703"
    static let civicsURL =
        "https://purdue.brightspace.com/d2l/lms/news/main.d2l?ou=412690"
}

/// The two courses with live API access on this tenant, reused from the
/// assignments suite so both halves of a submenu describe the same world.
private enum Real {
    static let scholarlyID = 440_703
    static let civicsID = 412_690
}

/// Instants computed with `python3`, independent of any Swift date arithmetic.
private enum Instant {
    /// `2026-08-16T12:00:00Z` — the fixed `now` for this suite.
    static let now = Date(timeIntervalSince1970: 1_786_881_600)
    /// `2026-07-17T12:00:00Z` — exactly 30 days before `now`.
    static let cutoff = Date(timeIntervalSince1970: 1_784_289_600)
    /// One second older than the cutoff.
    static let justPastCutoff = Date(timeIntervalSince1970: 1_784_289_599)
    /// One second after `now` — a scheduled post D2L has not published yet.
    static let justAfterNow = Date(timeIntervalSince1970: 1_786_881_601)

    /// `2026-08-10T15:00:00Z` — "Aug 10" in both zones.
    static let aug10 = Date(timeIntervalSince1970: 1_786_374_000)
    /// `2026-08-05T12:00:00Z` — a single-digit day, for the padding check.
    static let aug5 = Date(timeIntervalSince1970: 1_785_931_200)
    /// `2026-08-11T02:30:00Z` — 22:30 on **August 10** in Indiana. The whole
    /// reason `timeZone` is a parameter.
    static let lateNightAug10 = Date(timeIntervalSince1970: 1_786_415_400)

    /// Nine consecutive noons, `2026-08-01` … `2026-08-09`, all inside the
    /// window. Enough to overflow the cap of 5 with room to spare.
    static let augustNoons: [Date] = (0..<9).map {
        Date(timeIntervalSince1970: 1_785_585_600 + Double($0) * 86_400)
    }
}

// MARK: - Local helpers

private func announcement(
    id: Int,
    courseId: Int = Real.scholarlyID,
    title: String = "An Announcement",
    date: Date? = Instant.aug10
) -> Announcement {
    Announcement(id: id, courseId: courseId, title: title, date: date)
}

/// The announcement rows among these rows. `MenuModel` ships an `assignments`
/// accessor but no announcements one, and the contract is frozen, so the
/// equivalent lives here.
private func announcements(_ rows: [MenuRow]) -> [AnnouncementRow] {
    rows.compactMap { if case .announcement(let row) = $0 { row } else { nil } }
}

/// A course with a wide-open Access window, so it is CURRENT — and therefore
/// visible — at any test `now`. Undated shells are hidden entirely under the
/// 2026-08-24 user decision, so they can no longer host announcements in the
/// menu-level tests.
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

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — The window: which announcements qualify
// ═════════════════════════════════════════════════════════════════════════════

@Suite("section — the 30-day window decides what qualifies")
struct AnnouncementWindowTests {

    private func section(_ announcements: [Announcement]) -> [MenuRow] {
        AnnouncementTranslation.section(
            state: .loaded(announcements), courseId: Real.scholarlyID,
            now: Instant.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )
    }

    @Test("an announcement posted inside the window is shown")
    func recentAnnouncementQualifies() {
        // Arrange / Act — the ordinary case, asserted first so every exclusion
        // below is demonstrably an exclusion and not a function that shows nothing.
        let rows = self.section([announcement(id: 1, date: Instant.aug10)])

        // Assert
        #expect(announcements(rows).map(\.id) == [1])
    }

    @Test("an announcement exactly thirty days old still qualifies")
    func theCutoffBoundaryIsInclusive() {
        // Arrange / Act — inclusive, matching the convention `dueLabel` and the
        // currentness policy already use. An exclusive boundary would drop a post
        // one tick before the window's own edge.
        let rows = self.section([announcement(id: 1, date: Instant.cutoff)])

        // Assert
        #expect(announcements(rows).map(\.id) == [1])
    }

    @Test("an announcement one second older than the cutoff is dropped")
    func justPastTheCutoffIsExcluded() {
        // Arrange / Act — the other side of the same boundary. Without both, a
        // cutoff that never fires passes the test above.
        let rows = self.section([announcement(id: 1, date: Instant.justPastCutoff)])

        // Assert — no rows at all, therefore no section.
        #expect(rows.isEmpty)
    }

    @Test("an announcement posted exactly now is shown")
    func theNowBoundaryIsInclusive() {
        // Arrange / Act — a post is not "in the future" at the instant it appears.
        let rows = self.section([announcement(id: 1, date: Instant.now)])

        // Assert
        #expect(announcements(rows).map(\.id) == [1])
    }

    @Test("a future-scheduled announcement is not shown")
    func futureDatedAnnouncementsAreExcluded() {
        // Arrange / Act — a `StartDate` ahead of now is a post D2L has scheduled
        // and not yet published. Showing it announces something the student cannot
        // go and read.
        let rows = self.section([announcement(id: 1, date: Instant.justAfterNow)])

        // Assert
        #expect(rows.isEmpty)
    }

    @Test("an undated announcement is not shown")
    func undatedAnnouncementsAreExcluded() {
        // Arrange / Act — a cutoff cannot be applied to a date that does not
        // exist, and this list's entire ordering is by age, so an item of unknown
        // age has no correct position in it.
        let rows = self.section([announcement(id: 1, date: nil)])

        // Assert
        #expect(rows.isEmpty)
    }

    @Test("an undated announcement does not displace a dated one")
    func undatedAnnouncementsDoNotReachAPopulatedSection() {
        // Arrange — the mixed case, which the single-item test above cannot
        // distinguish from "undated items sort last".
        let input = [
            announcement(id: 1, date: nil),
            announcement(id: 2, date: Instant.aug10),
        ]

        // Act
        let rows = self.section(input)

        // Assert
        #expect(announcements(rows).map(\.id) == [2])
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 — Order and cap
// ═════════════════════════════════════════════════════════════════════════════

@Suite("section — newest first, capped at five")
struct AnnouncementOrderTests {

    private func section(_ announcements: [Announcement]) -> [MenuRow] {
        AnnouncementTranslation.section(
            state: .loaded(announcements), courseId: Real.scholarlyID,
            now: Instant.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )
    }

    @Test("announcements are ordered newest first")
    func newestComesFirst() {
        // Arrange — deliberately handed over oldest-first, so a passing result
        // cannot be an artifact of input order. This is the opposite of the
        // assignments half, where the SOONEST deadline leads: a deadline is a
        // future you act on, a posting date is a past you catch up on.
        let input = [
            announcement(id: 1, date: Instant.augustNoons[0]),
            announcement(id: 2, date: Instant.augustNoons[4]),
            announcement(id: 3, date: Instant.augustNoons[2]),
        ]

        // Act
        let ids = announcements(self.section(input)).map(\.id)

        // Assert
        #expect(ids == [2, 3, 1])
    }

    @Test("at most five announcements are shown")
    func theSectionIsCappedAtFive() throws {
        // Arrange — nine qualifying posts, which is a plausible fortnight in a
        // busy course. A submenu that grew without bound would push the
        // assignments above it off the top of the screen.
        let input = Instant.augustNoons.enumerated().map { announcement(id: $0.offset + 1, date: $0.element) }
        try #require(input.count == 9)

        // Act
        let ids = announcements(self.section(input)).map(\.id)

        // Assert — the five NEWEST, not the first five received.
        #expect(ids == [9, 8, 7, 6, 5])
    }

    @Test("the cap keeps the newest five even when they arrive last")
    func theCapKeepsTheNewestNotTheFirstReceived() {
        // Arrange — reversed input, so an implementation that truncates before
        // sorting keeps the five OLDEST and fails here while passing above.
        let input = Instant.augustNoons.enumerated()
            .map { announcement(id: $0.offset + 1, date: $0.element) }
            .reversed()

        // Act
        let ids = announcements(self.section(Array(input))).map(\.id)

        // Assert
        #expect(ids == [9, 8, 7, 6, 5])
    }

    @Test("announcements sharing a posting instant fall back to id")
    func tiesResolveDeterministically() {
        // Arrange — routine when a department posts a batch. Swift's sort is not
        // stable, so without a total order these would swap between refreshes and
        // `MenuModel`'s `Equatable` — which the GUI uses to skip rebuilding —
        // would compare unequal on identical data.
        let input = [
            announcement(id: 9, date: Instant.aug10),
            announcement(id: 4, date: Instant.aug10),
            announcement(id: 7, date: Instant.aug10),
        ]

        // Act
        let ids = announcements(self.section(input)).map(\.id)

        // Assert
        #expect(ids == [4, 7, 9])
    }

    @Test("a tie at the cap boundary resolves the same way every time")
    func theCapIsDeterministicAcrossTies() {
        // Arrange — six posts sharing one instant, so WHICH five survive the cap
        // is decided entirely by the tie-break. Without one, the section's
        // contents, not merely its order, would vary between refreshes.
        let input = [6, 3, 1, 5, 2, 4].map { announcement(id: $0, date: Instant.aug10) }

        // Act
        let ids = announcements(self.section(input)).map(\.id)

        // Assert
        #expect(ids == [1, 2, 3, 4, 5])
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — The section's shape, and the states behind it
// ═════════════════════════════════════════════════════════════════════════════

@Suite("section — shape, and the three announcement states")
struct AnnouncementSectionShapeTests {

    private func section(_ state: AnnouncementsState) -> [MenuRow] {
        AnnouncementTranslation.section(
            state: state, courseId: Real.scholarlyID,
            now: Instant.now, baseURL: Pinned.baseURL, timeZone: Pinned.utc
        )
    }

    @Test("a populated section leads with a separator and a header")
    func populatedSectionCarriesItsBoundaryAndLabel() throws {
        // Arrange
        let input = [
            announcement(id: 1, date: Instant.augustNoons[1]),
            announcement(id: 2, date: Instant.augustNoons[3]),
        ]

        // Act
        let rows = self.section(.loaded(input))

        // Assert — the label is mandatory here, unlike the assignments half's
        // conditional headers: this section is APPENDED to rows of another kind,
        // so without a label its rows read as more assignments.
        try #require(rows.count == 4)
        #expect(rows[0] == .separator)
        #expect(rows[1] == .sectionHeader(Pinned.header))
        #expect(announcements(Array(rows.dropFirst(2))).map(\.id) == [2, 1])
    }

    @Test("never fetched contributes nothing at all")
    func neverFetchedYieldsNoSection() {
        // Arrange / Act — every course's state at launch. Unlike the assignments
        // half, `[]` is right here: the submenu already exists because that half
        // fills it, so silence costs nothing and an empty section would put two
        // rows of noise in every course.
        let rows = self.section(.neverFetched)

        // Assert
        #expect(rows.isEmpty)
    }

    @Test("a successful empty fetch contributes nothing")
    func loadedEmptyYieldsNoSection() {
        // Arrange / Act — data, not an error: this course genuinely has no
        // announcements. A "No announcements" line would be a permanent apology
        // for a course that simply does not use the feature.
        let rows = self.section(.loaded([]))

        // Assert
        #expect(rows.isEmpty)
    }

    @Test("a course whose announcements are all stale gets no empty section")
    func allStaleYieldsNoSection() {
        // Arrange — the common shape late in a term: real announcements, all of
        // them older than the window. The header and separator must go with them.
        let input = [
            announcement(id: 1, date: Instant.justPastCutoff),
            announcement(id: 2, date: Date(timeIntervalSince1970: 1_770_000_000)),
        ]

        // Act
        let rows = self.section(.loaded(input))

        // Assert — not a bare header, not a bare separator: nothing.
        #expect(rows.isEmpty)
    }

    @Test("a failure never blanks a section that had announcements")
    func failedRendersLastKnown() {
        // Arrange — the normal case for this tenant: the session dies within
        // hours, so a refresh failing over data we already hold is routine.
        let known = [
            announcement(id: 1, date: Instant.augustNoons[1]),
            announcement(id: 2, date: Instant.augustNoons[3]),
        ]

        // Act
        let rows = self.section(.failed(lastKnown: known, error: .sessionExpired))

        // Assert
        #expect(announcements(rows).map(\.id) == [2, 1])
    }

    @Test("a failure renders exactly what a success would, with no note")
    func failedIsSilent() {
        // Arrange — the assignments half of this same submenu already appends
        // "Couldn't refresh — may be out of date" when its fetch failed, and both
        // routes fail together on one dead session. A second note would describe
        // one fault twice.
        let known = [announcement(id: 1, date: Instant.aug10)]

        // Act
        let failed = self.section(.failed(lastKnown: known, error: .sessionExpired))

        // Assert — identical to the loaded rendering, row for row.
        #expect(failed == self.section(.loaded(known)))
        #expect(!failed.contains { if case .message = $0 { true } else { false } })
    }

    @Test("a first failure with nothing known contributes nothing")
    func failedWithNothingKnownYieldsNoSection() {
        // Arrange / Act — a dead session on the very first fetch. Silence is right
        // because the assignments half is already saying that the fetch failed.
        let rows = self.section(.failed(lastKnown: [], error: .transport("offline")))

        // Assert
        #expect(rows.isEmpty)
    }

    @Test("a failure whose known announcements are all stale contributes nothing")
    func failedWithOnlyStaleKnownYieldsNoSection() {
        // Arrange / Act — the cutoff applies to `lastKnown` exactly as it does to
        // a fresh load; a failure does not license showing older posts.
        let rows = self.section(
            .failed(lastKnown: [announcement(id: 1, date: Instant.justPastCutoff)], error: .sessionExpired)
        )

        // Assert
        #expect(rows.isEmpty)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 1 & 2 — The row: what it says and where it goes
// ═════════════════════════════════════════════════════════════════════════════

@Suite("section — the rows it builds")
struct AnnouncementRowTests {

    private func rows(
        _ announcements: [Announcement],
        courseId: Int = Real.scholarlyID,
        timeZone: TimeZone = Pinned.utc
    ) -> [AnnouncementRow] {
        let section = AnnouncementTranslation.section(
            state: .loaded(announcements), courseId: courseId,
            now: Instant.now, baseURL: Pinned.baseURL, timeZone: timeZone
        )
        return section.compactMap { if case .announcement(let row) = $0 { row } else { nil } }
    }

    @Test("the title is carried verbatim")
    func titleIsVerbatim() throws {
        // Arrange — real announcement titles are sentences with punctuation, and
        // truncating or reformatting them is a decision nobody asked for.
        let input = [announcement(id: 1, title: "Exam 1 rooms posted — check your section.")]

        // Act
        let row = try #require(self.rows(input).first)

        // Assert
        #expect(row.title == "Exam 1 rooms posted — check your section.")
    }

    @Test("the subtitle is the absolute posting date")
    func subtitleIsTheFormattedPostingDate() throws {
        // Arrange — absolute, never "3 days ago": a relative string baked at
        // model-build time is already wrong by the time the menu is opened, which
        // is the exact staleness experiment 18 removed from the status row.
        let input = [announcement(id: 1, date: Instant.aug10)]

        // Act
        let row = try #require(self.rows(input).first)

        // Assert — no year, no time of day.
        #expect(row.subtitle == "Aug 10")
    }

    @Test("the day is not zero-padded")
    func singleDigitDaysAreNotPadded() throws {
        // Arrange / Act — guards against a formatter emitting "Aug 05".
        let row = try #require(self.rows([announcement(id: 1, date: Instant.aug5)]).first)

        // Assert
        #expect(row.subtitle == "Aug 5")
    }

    @Test("the time zone decides the calendar day, so a late-night post is not off by one")
    func timeZoneDecidesTheDay() throws {
        // Arrange — 2026-08-11T02:30:00Z is 22:30 on August 10 in Indiana. A
        // student who read the post last night must not be told it landed today.
        let input = [announcement(id: 1, date: Instant.lateNightAug10)]

        // Act
        let inUTC = try #require(self.rows(input, timeZone: Pinned.utc).first)
        let inIndiana = try #require(self.rows(input, timeZone: Pinned.indiana).first)

        // Assert — the whole reason `timeZone` is a parameter.
        #expect(inUTC.subtitle == "Aug 11")
        #expect(inIndiana.subtitle == "Aug 10")
    }

    @Test("the raw posting instant travels alongside the rendered one")
    func rawDateIsCarried() throws {
        // Arrange / Act — sorting and any future "since you last looked" filter
        // need the value, not the text.
        let row = try #require(self.rows([announcement(id: 1, date: Instant.aug10)]).first)

        // Assert
        #expect(row.date == Instant.aug10)
    }

    @Test("every row's URL comes from the courseId parameter, never from the announcement")
    func urlComesFromTheCourseParameter() throws {
        // Arrange — PRIORITY 2's cross-wiring case, forced: an announcement
        // stamped with the WRONG course, as a fan-out bug would produce. `ou=`
        // must still name the course whose submenu this is, because that is the
        // only value the row's position can be checked against. Getting it wrong
        // fails silently — the other course's announcements page is a real page.
        let mismatched = [announcement(id: 1, courseId: Real.civicsID, date: Instant.aug10)]

        // Act
        let row = try #require(self.rows(mismatched, courseId: Real.scholarlyID).first)

        // Assert
        #expect(row.url.absoluteString == Pinned.scholarlyURL)
    }

    @Test("every row in a section shares the one announcements page")
    func everyRowSharesTheCourseAnnouncementsPage() {
        // Arrange — D2L offers no per-item deep link worth trusting across
        // tenants, so one destination per course is the design, not a shortcut.
        let input = [
            announcement(id: 1, date: Instant.augustNoons[1]),
            announcement(id: 2, date: Instant.augustNoons[3]),
            announcement(id: 3, date: Instant.augustNoons[5]),
        ]

        // Act
        let urls = Set(self.rows(input, courseId: Real.civicsID).map(\.url.absoluteString))

        // Assert — the count guard is load-bearing: an empty set is trivially a
        // set of one thing that is also the wrong thing.
        #expect(self.rows(input, courseId: Real.civicsID).count == 3)
        #expect(urls == [Pinned.civicsURL])
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// PRIORITY 2 — The join: the section lands in the right submenu, after the work
// ═════════════════════════════════════════════════════════════════════════════

@Suite("The join — announcements reach the right course's submenu")
struct AnnouncementWiringTests {

    private static let assignmentsHeld = AssignmentsState.loaded([
        Assignment(
            id: 445_296, courseId: Real.scholarlyID, name: "Upload your CITI Certificate",
            dueDate: nil, isHidden: false, groupTypeId: nil
        ),
    ])

    private func menu(
        announcements: [Int: AnnouncementsState],
        assignments: [Int: AssignmentsState] = [:]
    ) -> MenuModel {
        MenuTranslation.menu(
            courses: [
                currentCourse(id: Real.scholarlyID, name: "Scholarly Project Milestones"),
                currentCourse(id: Real.civicsID, name: "Purdue Civics Knowledge Test"),
            ],
            lastFetch: Instant.now,
            now: Instant.now,
            baseURL: Pinned.baseURL,
            assignments: assignments,
            announcements: announcements,
            timeZone: Pinned.utc
        )
    }

    @Test("the section lands inside the submenu of the course it belongs to")
    func theSectionReachesItsOwnCourse() throws {
        // Arrange — only one of the two courses has announcements.
        let state = AnnouncementsState.loaded([announcement(id: 1, date: Instant.aug10)])

        // Act
        let model = self.menu(announcements: [Real.scholarlyID: state])

        // Assert
        let scholarly = try #require(model.course(id: Real.scholarlyID))
        let civics = try #require(model.course(id: Real.civicsID))
        #expect(announcements(scholarly.submenu).map(\.id) == [1])
        #expect(announcements(civics.submenu).isEmpty)
    }

    @Test("the section sits after the assignment rows, not among them")
    func theSectionFollowsTheAssignments() throws {
        // Arrange — a course with both halves populated, which is the shape the
        // whole submenu is designed around: what you owe first, then what was said.
        let announced = AnnouncementsState.loaded([announcement(id: 1, date: Instant.aug10)])

        // Act
        let model = self.menu(
            announcements: [Real.scholarlyID: announced],
            assignments: [Real.scholarlyID: Self.assignmentsHeld]
        )

        // Assert
        let rows = try #require(model.course(id: Real.scholarlyID)?.submenu)
        let lastAssignment = try #require(rows.lastIndex { if case .assignment = $0 { true } else { false } })
        let header = try #require(rows.firstIndex(of: .sectionHeader(Pinned.header)))
        let firstAnnouncement = try #require(rows.firstIndex { if case .announcement = $0 { true } else { false } })
        #expect(lastAssignment < header)
        #expect(header < firstAnnouncement)
    }

    @Test("an announcement never carries a neighbouring course's page")
    func announcementsDoNotCrossCourses() throws {
        // Arrange — PRIORITY 2. Both courses hold announcements at once, so a
        // shared or last-wins course id produces a valid Brightspace URL pointing
        // at somebody else's announcements page.
        let states: [Int: AnnouncementsState] = [
            Real.scholarlyID: .loaded([announcement(id: 1, courseId: Real.scholarlyID, date: Instant.aug10)]),
            Real.civicsID: .loaded([announcement(id: 2, courseId: Real.civicsID, date: Instant.aug10)]),
        ]

        // Act
        let model = self.menu(announcements: states)

        // Assert — checked per course, so a failure names which one leaked.
        for courseId in [Real.scholarlyID, Real.civicsID] {
            let course = try #require(model.course(id: courseId))
            let rows = announcements(course.submenu)
            try #require(!rows.isEmpty, "course \(courseId) rendered no announcements")
            for row in rows {
                #expect(
                    row.url.absoluteString.contains("ou=\(courseId)"),
                    "announcement \(row.id) in course \(courseId) points at another course"
                )
            }
        }
    }

    @Test("announcements appear only inside submenus, never at the top level")
    func announcementsDoNotLeakToTheTopLevel() {
        // Arrange / Act — `.announcement` is documented as a submenu-only row. A
        // leak would render an announcement as a sibling of the courses.
        let model = self.menu(
            announcements: [Real.scholarlyID: .loaded([announcement(id: 1, date: Instant.aug10)])]
        )

        // Assert
        #expect(announcements(model.rows).isEmpty)
    }

    @Test("omitting announcements leaves the menu exactly as it was")
    func theDefaultReproducesThePreAnnouncementMenu() {
        // Arrange — the regression guard for every existing call site. A course
        // absent from the map is `neverFetched`, which contributes no rows, so the
        // defaulted parameter must produce a byte-identical model.
        let assignments = [Real.scholarlyID: Self.assignmentsHeld]

        // Act
        let withEmptyMap = self.menu(announcements: [:], assignments: assignments)
        let withoutTheArgument = MenuTranslation.menu(
            courses: [
                currentCourse(id: Real.scholarlyID, name: "Scholarly Project Milestones"),
                currentCourse(id: Real.civicsID, name: "Purdue Civics Knowledge Test"),
            ],
            lastFetch: Instant.now,
            now: Instant.now,
            baseURL: Pinned.baseURL,
            assignments: assignments,
            timeZone: Pinned.utc
        )

        // Assert — the guard matters: two empty models compare equal trivially.
        #expect(!withEmptyMap.courses.isEmpty)
        #expect(withEmptyMap == withoutTheArgument)
    }

    @Test("translation is deterministic even when the announcements arrive shuffled")
    func shuffledAnnouncementsYieldTheSameModel() {
        // Arrange — `MenuModel`'s `Equatable` is what lets the GUI skip rebuilding
        // an unchanged menu, so an order-dependent section would rebuild the whole
        // menu on every timer tick.
        let posts = Instant.augustNoons.enumerated().map { announcement(id: $0.offset + 1, date: $0.element) }

        // Act
        let a = self.menu(announcements: [Real.scholarlyID: .loaded(posts)])
        let b = self.menu(announcements: [Real.scholarlyID: .loaded(posts.reversed())])

        // Assert — the count guard is load-bearing: two models that both render
        // nothing are also equal.
        #expect(announcements(a.course(id: Real.scholarlyID)?.submenu ?? []).count == Pinned.cap)
        #expect(a == b, "section order depends on input order")
    }
}
