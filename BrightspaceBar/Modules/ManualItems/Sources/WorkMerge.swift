import Foundation

/// One entry of the combined list a course/day submenu will render: either
/// something the daemon fetched or something the student typed. The GUI's
/// only question — "do I show the ✕?" — is `isManual`.
///
/// Generic over the fetched type on purpose. Another agent is reshaping the
/// adapter's types *right now*; depending on any of them here would couple two
/// concurrent edits. The adapter maps its own item into `Fetched` and hands
/// this module accessors for the two fields sorting needs.
public enum MergedWorkItem<Fetched: Equatable & Sendable>: Equatable, Sendable {
    case fetched(Fetched)
    case manual(ManualItem)

    /// True exactly for the student's own items — the delete affordance
    /// appears on these and only these.
    public var isManual: Bool {
        if case .manual = self { return true }
        return false
    }
}

/// The pure merge: fetched items and manual items in, one sorted list out.
///
/// Ordering — deterministic, so an unchanged model compares `==` and skips the
/// menu rebuild (the `Equatable`-skip pattern the assembler relies on):
///
///   1. Due date ascending; an undated fetched item sorts LAST (no deadline →
///      no urgency). Manual items always have a date.
///   2. Name, case-insensitively — so "quiz 3" and "Quiz 3" don't shuffle on
///      refetch.
///   3. Fetched before manual — a stable tiebreak that also reads right: the
///      official item first, the student's annotation after it.
///
/// Input order is otherwise irrelevant; callers pass whatever slices (one
/// course, one day) they already filtered. This function filters nothing.
public func mergeWorkItems<Fetched: Equatable & Sendable>(
    fetched: [Fetched],
    manual: [ManualItem],
    dueOf: (Fetched) -> Date?,
    nameOf: (Fetched) -> String
) -> [MergedWorkItem<Fetched>] {
    // Sort key materialized up front so accessors run once per item, and so
    // the comparator itself stays a pure comparison. A tuple, not a nested
    // struct — Swift forbids types nested in generic functions.
    typealias Keyed = (due: Date?, name: String, manualRank: Int, entry: MergedWorkItem<Fetched>)
    let keyed: [Keyed] =
        fetched.map { (dueOf($0), nameOf($0), 0, .fetched($0)) }
        + manual.map { ($0.due, $0.name, 1, .manual($0)) }

    return keyed.sorted { lhs, rhs in
        switch (lhs.due, rhs.due) {
        case let (l?, r?) where l != r: return l < r
        case (nil, .some): return false   // undated last
        case (.some, nil): return true
        default: break                    // equal dates, or both nil
        }
        let names = lhs.name.caseInsensitiveCompare(rhs.name)
        if names != .orderedSame { return names == .orderedAscending }
        return lhs.manualRank < rhs.manualRank
    }.map(\.entry)
}
