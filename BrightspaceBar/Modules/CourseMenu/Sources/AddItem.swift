import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Intent 1: the add-your-own-item vocabulary, contract side.
//
// The GUI renders three mini-forms per course submenu — Add assignment, Add
// quiz, Add test — and hands back what the student typed as an `AddItemDraft`.
// What happens to a draft (persisting a manual item, rebuilding the menu) is
// the composition root's wiring; nothing here names a store, a file, or a
// backend type, for the same reason nothing else in this module does.
// ─────────────────────────────────────────────────────────────────────────────

/// What kind of work an add-form creates. The KIND IS THE SECTION: each form is
/// pre-scoped to one case and the student is never asked, so a draft's kind is
/// decided by which form was filled in, structurally.
///
/// `CaseIterable` order is display order — assignment, quiz, test — and the
/// translation layer emits the three forms by iterating it, so the order is
/// stated once.
public enum AddItemKind: String, Equatable, Sendable, CaseIterable {
    case assignment
    case quiz
    case test

    /// The form's heading, pre-decided here rather than in view code for the
    /// same reason every other label is: wording is policy.
    public var formHeading: String {
        switch self {
        case .assignment: "Add assignment"
        case .quiz: "Add quiz"
        case .test: "Add test"
        }
    }
}

/// One inline mini-form row inside a course's submenu. Pure data: the GUI
/// hosts the actual fields, and everything it needs to do so is these two
/// facts. Three of these appear per course, one per `AddItemKind`.
public struct AddItemFormRow: Equatable, Sendable {
    /// The course the created item will belong to — the same id namespace
    /// `CourseRow.id` uses, stamped by the translation layer so a form in
    /// course A's submenu structurally cannot create course B's item.
    public let courseId: Int
    public let kind: AddItemKind

    public init(courseId: Int, kind: AddItemKind) {
        self.courseId = courseId
        self.kind = kind
    }
}

/// What the student typed, handed across the seam when Add is clicked. Values
/// only — the link is an opaque pasted string, deliberately not a `URL`,
/// because nothing on the GUI side should parse (and thereby reject) what the
/// student pasted; validation policy lives with the manual-item type.
public struct AddItemDraft: Equatable, Sendable {
    public let courseId: Int
    public let kind: AddItemKind
    public let name: String
    public let link: String
    public let due: Date

    public init(courseId: Int, kind: AddItemKind, name: String, link: String, due: Date) {
        self.courseId = courseId
        self.kind = kind
        self.name = name
        self.link = link
        self.due = due
    }
}

/// The due-date control's seed value, as pure policy the GUI reads rather than
/// invents: TODAY at 11:59 PM, in the menu's zone.
///
/// 23:59 because that is when coursework is due — Brightspace's own default —
/// and a picked date should start where the student will almost always leave
/// it. A pure function of `now` and `timeZone` (never `Date()` inline) so the
/// default is hermetically testable, DST days included.
public enum AddItemDefaults {
    public static func defaultDue(now: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Pinned so no ambient locale can reach the calendar's behaviour —
        // the same rule every pure date computation in this package follows.
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let start = calendar.startOfDay(for: now)
        // Components forward from local midnight, never `start + 86_340`
        // seconds: on a DST-transition day the two differ by an hour, and the
        // whole point of a picked date is that it says what it looks like.
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: start) ?? start
    }
}
