import Foundation

/// One piece of work the *student* typed in, not one D2L reported.
///
/// This is Intent 1 of the redesign: David knows about a test the professor
/// only announced aloud, adds it by hand, and it rides the same menu as the
/// fetched items. The type is deliberately parallel to — but independent of —
/// `AssignmentPipeline.Assignment`: a manual item has no D2L id, no hidden
/// flag, no group, and its link is whatever the student pasted. Sharing a type
/// would force fake sentinels into fields the daemon owns.
public struct ManualItem: Codable, Sendable, Equatable, Identifiable {

    /// What the student says it is. Stored as its raw string in JSON so the
    /// file stays human-readable and a future kind doesn't break old files'
    /// *other* entries — decoding is per-item only at the store's snapshot
    /// level, and an unknown kind fails that one file loudly rather than
    /// silently dropping items.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case assignment
        case quiz
        case test
    }

    /// Stable identity, minted once at creation and preserved across every
    /// save. Deletion and undo key off it, so it must never be re-derived
    /// from the mutable fields.
    public let id: UUID

    /// The daemon's org-unit id for the course this belongs to — the same
    /// `Int` namespace `Course.id` uses, so the adapter can group manual and
    /// fetched items under one course without a mapping table.
    public let courseId: Int

    public let kind: Kind

    /// The name as the student typed it. Shown verbatim.
    public let name: String

    /// Where clicking should go. **Opaque**: the student pasted it, the app
    /// opens it, and nothing in between parses it. The only rule is that it
    /// is non-empty — an empty link would render a row that clicks into
    /// nothing, so `init` refuses it at the one place items are born.
    public let link: String

    /// When it is due. Non-optional, unlike the fetched side: a student adds
    /// an item *because* it has a deadline; an undated manual item has no
    /// reason to exist and no day to appear under.
    public let due: Date

    /// The one constructor. Returns nil for an empty (or all-whitespace)
    /// link — the single validation this type performs.
    public init?(
        id: UUID = UUID(),
        courseId: Int,
        kind: Kind,
        name: String,
        link: String,
        due: Date
    ) {
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.id = id
        self.courseId = courseId
        self.kind = kind
        self.name = name
        self.link = link
        self.due = due
    }
}
