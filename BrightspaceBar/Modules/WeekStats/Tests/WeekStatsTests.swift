import Foundation
import Testing
import WeekStats

// ─────────────────────────────────────────────────────────────────────────────
// WeekStats is pure, so every test is values in, values out — no clock reads,
// no locale dependence. Calendars are built by hand (Gregorian, explicit
// firstWeekday, explicit time zone) so the week boundaries under test are the
// ones asserted, on any machine.
// ─────────────────────────────────────────────────────────────────────────────

private let utc = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!

private func gregorian(firstWeekday: Int) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = firstWeekday
    return cal
}

/// A moment from civil components in a zone, so boundary tests state their
/// intent in dates rather than epoch arithmetic.
private func moment(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 12, _ minute: Int = 0,
    in zone: TimeZone
) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func item(_ name: String, _ kind: WorkKind, due: Date, url: URL? = nil) -> WeekWorkItem {
    WeekWorkItem(name: name, kind: kind, due: due, url: url)
}

// ── Week membership ──────────────────────────────────────────────────────────

@Test func countsRespectSundayFirstWeekBoundaries() {
    // Wed Aug 19 2026, Sunday-first calendar → week is Sun Aug 16 … Sat Aug 22.
    let now = moment(2026, 8, 19, in: utc)
    let cal = gregorian(firstWeekday: 1)
    let items = [
        item("In: Sunday start", .assignment, due: moment(2026, 8, 16, 0, 0, in: utc)),
        item("In: Saturday night", .quiz, due: moment(2026, 8, 22, 23, 59, in: utc)),
        item("Out: last Saturday", .assignment, due: moment(2026, 8, 15, 23, 59, in: utc)),
        item("Out: next Sunday 00:00", .assignment, due: moment(2026, 8, 23, 0, 0, in: utc)),
    ]
    let stats = WeekStatsBuilder.stats(items: items, now: now, calendar: cal, timeZone: utc)
    #expect(stats.counts == [.assignment: 1, .quiz: 1])
}

@Test func countsRespectMondayFirstWeekBoundaries() {
    // Same Wednesday, Monday-first calendar → week is Mon Aug 17 … Sun Aug 23.
    let now = moment(2026, 8, 19, in: utc)
    let cal = gregorian(firstWeekday: 2)
    let items = [
        item("Out under Monday-first: Sun Aug 16", .assignment, due: moment(2026, 8, 16, 0, 0, in: utc)),
        item("In: Monday 00:00 exactly", .assignment, due: moment(2026, 8, 17, 0, 0, in: utc)),
        item("In: Sunday Aug 23", .test, due: moment(2026, 8, 23, 10, 0, in: utc)),
        item("Out: Monday Aug 24 00:00", .quiz, due: moment(2026, 8, 24, 0, 0, in: utc)),
    ]
    let stats = WeekStatsBuilder.stats(items: items, now: now, calendar: cal, timeZone: utc)
    #expect(stats.counts == [.assignment: 1, .test: 1])
}

@Test func dstTransitionWeekStillHasCivilBoundaries() {
    // US spring-forward: Sun Mar 8 2026, 2am → 3am in New York. The week
    // containing that Sunday is 167 hours long; Calendar's interval must still
    // run civil-midnight to civil-midnight. Sunday-first: Mar 8 … Mar 14.
    let now = moment(2026, 3, 10, in: newYork)
    let cal = gregorian(firstWeekday: 1)
    let items = [
        item("In: week start midnight", .assignment, due: moment(2026, 3, 8, 0, 0, in: newYork)),
        item("In: Saturday 23:59", .quiz, due: moment(2026, 3, 14, 23, 59, in: newYork)),
        item("Out: next Sunday 00:00", .quiz, due: moment(2026, 3, 15, 0, 0, in: newYork)),
    ]
    let stats = WeekStatsBuilder.stats(items: items, now: now, calendar: cal, timeZone: newYork)
    #expect(stats.counts == [.assignment: 1, .quiz: 1])
    // And the naive 7×86400 math would disagree: the true week is one hour short.
    let week = { var c = cal; c.timeZone = newYork; return c.dateInterval(of: .weekOfYear, for: now)! }()
    #expect(week.duration == 167 * 3600)
}

// ── Next selection ───────────────────────────────────────────────────────────

@Test func nextMayBeBeyondTheCurrentWeek() {
    // Nothing due this week; the midterm two weeks out is still "next".
    let now = moment(2026, 8, 19, in: utc)
    let midterm = item("Midterm", .test, due: moment(2026, 9, 2, in: utc), url: URL(string: "https://d2l.example/quiz")!)
    let past = item("Old HW", .assignment, due: moment(2026, 8, 1, in: utc))
    let stats = WeekStatsBuilder.stats(items: [past, midterm], now: now, calendar: gregorian(firstWeekday: 1), timeZone: utc)
    #expect(stats.counts.isEmpty)
    #expect(stats.next == midterm)
}

@Test func nextAtExactlyNowCountsAsUpcoming() {
    let now = moment(2026, 8, 19, in: utc)
    let due = item("Due right now", .assignment, due: now)
    let stats = WeekStatsBuilder.stats(items: [due], now: now, calendar: gregorian(firstWeekday: 1), timeZone: utc)
    #expect(stats.next == due)
}

@Test func nextTieBreaksByNameThenKindRegardlessOfInputOrder() {
    let now = moment(2026, 8, 19, in: utc)
    let due = moment(2026, 8, 20, in: utc)
    let a = item("Alpha", .quiz, due: due)
    let b = item("Beta", .assignment, due: due)
    let aTest = item("Alpha", .assignment, due: due)  // same instant, same name → kind decides
    for permutation in [[a, b, aTest], [b, aTest, a], [aTest, a, b]] {
        let stats = WeekStatsBuilder.stats(items: permutation, now: now, calendar: gregorian(firstWeekday: 1), timeZone: utc)
        #expect(stats.next == aTest)
    }
}

@Test func emptyInputYieldsEmptyStats() {
    let stats = WeekStatsBuilder.stats(
        items: [], now: moment(2026, 8, 19, in: utc),
        calendar: gregorian(firstWeekday: 1), timeZone: utc)
    #expect(stats.counts.isEmpty)
    #expect(stats.next == nil)
}

@Test func nothingUpcomingYieldsNilNextButPastWeekItemsStillCount() {
    // An item due earlier this same week: counted, but not "next".
    let now = moment(2026, 8, 19, in: utc)
    let earlier = item("Turned in Monday", .assignment, due: moment(2026, 8, 17, in: utc))
    let stats = WeekStatsBuilder.stats(items: [earlier], now: now, calendar: gregorian(firstWeekday: 1), timeZone: utc)
    #expect(stats.counts == [.assignment: 1])
    #expect(stats.next == nil)
}

// ── Aggregate ────────────────────────────────────────────────────────────────

@Test func aggregateUnionsCountsAndPicksEarliestNextAcrossCourses() {
    let now = moment(2026, 8, 19, in: utc)
    let courseA = [
        item("A HW", .assignment, due: moment(2026, 8, 20, in: utc)),
        item("A Quiz", .quiz, due: moment(2026, 8, 21, in: utc)),
    ]
    let courseB = [
        item("B HW", .assignment, due: moment(2026, 8, 19, 13, 0, in: utc)),
    ]
    let stats = WeekStatsBuilder.aggregate(
        courses: [courseA, courseB], now: now,
        calendar: gregorian(firstWeekday: 1), timeZone: utc)
    #expect(stats.counts == [.assignment: 2, .quiz: 1])
    #expect(stats.next?.name == "B HW")
}

// ── Formatters ───────────────────────────────────────────────────────────────

@Test func countsLineOmitsZerosAndPluralizes() {
    #expect(WeekStatsFormat.countsLine([.assignment: 2, .quiz: 1]) == "2 assignments · 1 quiz")
    #expect(WeekStatsFormat.countsLine([.quiz: 2]) == "2 quizzes")
    #expect(WeekStatsFormat.countsLine([.test: 1]) == "1 test")
    #expect(WeekStatsFormat.countsLine([.assignment: 1, .quiz: 3, .test: 2]) == "1 assignment · 3 quizzes · 2 tests")
}

@Test func countsLineIsNilWhenNothingIsDue() {
    #expect(WeekStatsFormat.countsLine([:]) == nil)
    #expect(WeekStatsFormat.countsLine([.assignment: 0]) == nil)
}

@Test func nextLineUsesFixedWeekdayTableInTheGivenZone() {
    // Thu Aug 20 2026, 01:00 UTC is still Wednesday evening in New York.
    let due = moment(2026, 8, 20, 1, 0, in: utc)
    let hw = item("Homework 4", .assignment, due: due)
    #expect(WeekStatsFormat.nextLine(hw, calendar: gregorian(firstWeekday: 1), timeZone: utc) == "next: Homework 4 · Thu")
    #expect(WeekStatsFormat.nextLine(hw, calendar: gregorian(firstWeekday: 1), timeZone: newYork) == "next: Homework 4 · Wed")
}
