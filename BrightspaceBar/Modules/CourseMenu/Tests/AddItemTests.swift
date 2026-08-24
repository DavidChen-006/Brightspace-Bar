import Foundation
import Testing

@testable import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// THE ADD-ITEM VOCABULARY (Intent 1) — the contract half of the mini-forms.
//
// PRIORITIES:
//
//   1. THE DEFAULT DUE DATE IS POLICY, AND POLICY IS PINNED. "Today, 11:59 PM,
//      in the menu's zone" is what the date picker opens on, and the student
//      will usually leave it there — so a wrong default is a wrong deadline on
//      most manual items. The DST day is the case naive arithmetic gets wrong.
//
//   2. THE KIND ORDER IS THE SECTION ORDER. The translation layer emits one
//      form per `allCases` element, so this order IS the submenu's layout, and
//      a reorder here silently reorders every course's submenu.
//
// SCOPE: all small. Pure values, injected instants, no clock anywhere.
// ═════════════════════════════════════════════════════════════════════════════

private let indiana = TimeZone(identifier: "America/Indianapolis")!

@Suite("AddItem — kinds, headings, and the default deadline")
struct AddItemTests {

    // ── Priority 2: the kind order and the headings ──────────────────────────

    @Test("the section order is assignment, quiz, test")
    func kindOrderIsPinned() {
        #expect(AddItemKind.allCases == [.assignment, .quiz, .test])
    }

    @Test("each form's heading names its kind and only its kind")
    func headingsArePinned() {
        // The exact strings, because they are the section headers of the
        // redesign ("Add assignment" / "Add quiz" / "Add test") — a reword is
        // a design change, not a refactor.
        #expect(AddItemKind.assignment.formHeading == "Add assignment")
        #expect(AddItemKind.quiz.formHeading == "Add quiz")
        #expect(AddItemKind.test.formHeading == "Add test")
    }

    // ── Priority 1: the default deadline ─────────────────────────────────────

    @Test("the default due date is today at 11:59 PM local")
    func defaultIsTonightAtElevenFiftyNine() {
        // Arrange — 10:00 on Tue Feb 10 2026 in Indiana (15:00Z), the same
        // pinned Tuesday the graph suites use.
        let now = Date(timeIntervalSince1970: 1_770_735_600)

        // Act
        let due = AddItemDefaults.defaultDue(now: now, timeZone: indiana)

        // Assert — read back through the same zone: 23:59:00 on that same day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = indiana
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
        #expect(parts.year == 2026)
        #expect(parts.month == 2)
        #expect(parts.day == 10)
        #expect(parts.hour == 23)
        #expect(parts.minute == 59)
        #expect(parts.second == 0)
    }

    @Test("late evening still defaults to TONIGHT, not tomorrow")
    func lateEveningStaysOnItsOwnDay() {
        // Arrange — 23:30 local on Feb 12 is 04:30Z on Feb 13: the instant
        // whose UTC day is tomorrow. The default must follow the LOCAL day.
        let lateNight = Date(timeIntervalSince1970: 1_770_957_000)

        // Act
        let due = AddItemDefaults.defaultDue(now: lateNight, timeZone: indiana)

        // Assert — still Feb 12, and only 29 minutes ahead of `now`.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = indiana
        let parts = calendar.dateComponents([.day, .hour, .minute], from: due)
        #expect(parts.day == 12)
        #expect(parts.hour == 23)
        #expect(parts.minute == 59)
    }

    @Test("the spring-forward day still defaults to 11:59 PM, not 12:59 AM")
    func dstDayIsComputedByComponents() {
        // Arrange — Sun Mar 8 2026, the US spring-forward day: 23 hours long
        // in Indiana. Midnight local is 05:00Z; naive `midnight + 86 340s`
        // lands at 00:59 the NEXT day. 12:00 local that day = 16:00Z.
        let noonOnDstDay = Date(timeIntervalSince1970: 1_772_985_600)

        // Act
        let due = AddItemDefaults.defaultDue(now: noonOnDstDay, timeZone: indiana)

        // Assert
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = indiana
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: due)
        #expect(parts.month == 3)
        #expect(parts.day == 8)
        #expect(parts.hour == 23)
        #expect(parts.minute == 59)
    }
}
