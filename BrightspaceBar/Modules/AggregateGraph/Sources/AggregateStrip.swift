import Foundation
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// Intent 3, the pure half: N per-course strips → ONE "All classes" strip.
//
//   CourseMenu.GraphCell (per course)   ← input vocabulary
//   AggregateCell / AggregateDayDetail  ← output vocabulary, owned here
//
// Same purity rules as GraphTranslation: values in, values out, no clock, no
// zone, no locale. This module deliberately does NOT re-derive anything from
// dates — it never sees one. Everything positional (day index, isToday, the
// caption's date half) is taken from the per-course strips, which all came out
// of the same `GraphTranslation.strip(now:timeZone:)` window by construction.
//
// WHY CELLS, NOT COUNTS. The task of combining intensities looks like it needs
// the underlying per-day item counts, but GraphTranslation's tier is not a
// bucketing of counts at all: a day's tier is `itemsDueThatDay.map(\.tier).max()`
// (a fold over item KINDS — see `GraphTranslation.tier(of:)`). `max` is
// associative, so
//
//   max(course A's items ∪ course B's items) == max(max(A), max(B))
//
// and aggregating the finished cells' tiers with `max` is EXACT, not a lossy
// re-bucketing. There are no count thresholds to import or mirror. That
// argument holds only while `CellTier`'s `<` follows the importance rank, so
// `AggregateStripTests.tierOrderingPin` pins it — a re-ranked or count-based
// tier scheme breaks loudly there, which is the signal to revisit this input
// type.
// ─────────────────────────────────────────────────────────────────────────────

/// One course's contribution to the aggregate: the label the popup's section
/// header will show ("CS 25200") plus the strip GraphTranslation already built.
public struct CourseStrip: Equatable, Sendable {
    /// What the aggregate popup names this course as. Caller-supplied; the
    /// aggregate preserves caller order, so this is also the section order.
    public let label: String
    /// The course's `CourseRow.graph`, unmodified.
    public let cells: [GraphCell]

    public init(label: String, cells: [GraphCell]) {
        self.label = label
        self.cells = cells
    }
}

/// One course's slice of an aggregate day's popup: the section header plus
/// that course's items, in the order GraphTranslation put them in.
public struct AggregateDaySection: Equatable, Sendable {
    public let courseLabel: String
    /// Never empty by contract — a course with nothing due that day gets no
    /// section, not an empty one (same shape as `GraphDayDetail.items`).
    public let items: [GraphDayItem]

    public init(courseLabel: String, items: [GraphDayItem]) {
        self.courseLabel = courseLabel
        self.items = items
    }
}

/// Everything the aggregate popup for one non-empty day says.
///
/// A NEW type rather than a widened `GraphDayDetail`, on purpose: the contract
/// type is caption + flat items, and the aggregate popup renders course
/// headers between groups. Encoding the grouping in item ordering would leave
/// the renderer nothing to draw a header FROM (a `GraphDayItem` carries no
/// course), and adding a course field to the contract would touch CourseMenu —
/// the frozen surface — for a feature only the aggregate needs. Sections here
/// cost the contract nothing and hand the renderer exactly the structure it
/// draws.
public struct AggregateDayDetail: Equatable, Sendable {
    /// Pre-formatted, e.g. "Thu Aug 27 · everything due" — same policy home as
    /// `GraphDayDetail.caption`. The date half is taken verbatim from a
    /// per-course caption for that day, so the two popups can never disagree
    /// about what day a column is.
    public let caption: String
    /// One entry per course with work due that day, in caller-supplied course
    /// order; items keep their in-course order. Never empty by contract.
    public let sections: [AggregateDaySection]

    public init(caption: String, sections: [AggregateDaySection]) {
        self.caption = caption
        self.sections = sections
    }
}

/// One day in the aggregate strip. The `tier`/`isToday` halves are exactly
/// `GraphCell`'s — same renderer vocabulary — but `detail` is the grouped
/// aggregate kind, which is why this is its own type rather than a `GraphCell`
/// with its meaning bent.
public struct AggregateCell: Equatable, Sendable {
    /// The most important work due that day across ALL courses; nil is a day
    /// with nothing due anywhere. Exact, not re-bucketed — see the header.
    public let tier: CellTier?
    /// True iff any input strip marks this index as today. All strips built
    /// from one `now` agree, so this is a pass-through, not a vote — OR rather
    /// than "first strip's flag" only so a malformed input cannot silently
    /// LOSE the indicator.
    public let isToday: Bool
    /// The grouped popup, or nil. Nil for an empty day, and for a day whose
    /// input cells carry fills but no details (strips built without link
    /// context) — the same safe degradation `GraphCell.detail` documents.
    public let detail: AggregateDayDetail?

    public init(tier: CellTier?, isToday: Bool = false, detail: AggregateDayDetail? = nil) {
        self.tier = tier
        self.isToday = isToday
        self.detail = detail
    }
}

/// The one way this module can fail. A typed error rather than a precondition
/// because the inputs are network-derived at one remove — a daemon hiccup that
/// yields one short strip should degrade to "no aggregate this cycle", never
/// crash the menu bar.
public enum AggregateGraphError: Error, Equatable, Sendable {
    /// Two input strips disagree about the day axis. Carries enough to log
    /// which course broke ranks.
    case mismatchedStripLengths(expected: Int, courseLabel: String, actual: Int)
}

public enum AggregateGraph {

    /// The caption's suffix — what the aggregate says where a per-course
    /// caption says the course label.
    public static let captionSuffix = "everything due"

    /// N same-length per-course strips → the ONE combined strip.
    ///
    /// Deterministic by construction: per-day tier is an order-free `max`,
    /// sections follow caller-supplied course order, items keep their
    /// in-course order, and the caption's date half comes from the FIRST
    /// course (in that same order) with a detail that day.
    ///
    /// - Returns: a strip the length of the shared day axis; `[]` for no
    ///   courses, which honestly says "no aggregate", not "112 empty days".
    /// - Throws: `AggregateGraphError.mismatchedStripLengths` when any strip's
    ///   length differs from the first's.
    public static func combined(_ strips: [CourseStrip]) throws -> [AggregateCell] {
        guard let expected = strips.first?.cells.count else { return [] }
        for strip in strips where strip.cells.count != expected {
            throw AggregateGraphError.mismatchedStripLengths(
                expected: expected, courseLabel: strip.label, actual: strip.cells.count
            )
        }

        return (0..<expected).map { day in
            let column = strips.map { (label: $0.label, cell: $0.cells[day]) }
            return AggregateCell(
                tier: column.compactMap(\.cell.tier).max(),
                isToday: column.contains { $0.cell.isToday },
                detail: self.detail(for: column)
            )
        }
    }

    /// The grouped popup for one day's column of per-course cells, or nil when
    /// no cell contributes a detail.
    private static func detail(
        for column: [(label: String, cell: GraphCell)]
    ) -> AggregateDayDetail? {
        let sections = column.compactMap { entry -> (caption: String, section: AggregateDaySection)? in
            guard let detail = entry.cell.detail, !detail.items.isEmpty else { return nil }
            return (detail.caption, AggregateDaySection(courseLabel: entry.label, items: detail.items))
        }
        guard let first = sections.first else { return nil }
        return AggregateDayDetail(
            caption: self.dateHalf(of: first.caption) + " · " + Self.captionSuffix,
            sections: sections.map(\.section)
        )
    }

    /// "Thu Aug 27 · CS 25200" → "Thu Aug 27"; a caption with no separator is
    /// already just the date (GraphTranslation with no course label). Splitting
    /// on the FIRST " · " is safe because the date half is built from fixed
    /// English tables (`weekdayNames`/`monthNames`) and can never contain it —
    /// only the course label after it could, and that half is discarded.
    private static func dateHalf(of caption: String) -> String {
        guard let range = caption.range(of: " · ") else { return caption }
        return String(caption[..<range.lowerBound])
    }
}
