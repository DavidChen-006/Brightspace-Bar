import Foundation
import CoursePipeline

/// The `AssignmentSource` the app ships with: one course's work, read out of the
/// cache the course fetch already produced.
///
/// It takes paths and **no runner**, so it structurally cannot spawn anything.
/// That is the whole cost argument: `fetchAssignments` is called once per visible
/// course — 27 times on David's account — and all 27 answers are already inside
/// the one `data.json` the daemon just wrote. A source that spawned per course
/// would climb the login ladder 27 times per refresh.
///
/// The mapping is the risk here. The daemon's item shape is not the Swift
/// model's: `title` on the wire is `name` in the model, `kind` is a string, the
/// precomputed `url` is ignored (Swift derives its own with `AssignmentLink`),
/// and `isHidden`/`groupTypeId` are not sent at all. Nothing in either language
/// checks the other, so each of those is a place a silent wrong answer could
/// appear — a quiz rendered with an assignment's deep link opens a page that does
/// not exist.
public struct DaemonAssignmentSource: AssignmentSource {

    private let paths: DaemonPaths

    public init(paths: DaemonPaths) {
        self.paths = paths
    }

    public func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        if let failure = DaemonCache.statusFailure(at: self.paths) { throw failure }
        guard let bytes = DaemonCache.dataBytes(at: self.paths) else {          // effect
            throw CourseSourceError.transport("no daemon cache has been written yet")
        }
        return try Self.decode(bytes, courseId: courseId)                       // pure
    }

    // MARK: - Deciding: the wire shape becomes the model

    /// One course's items out of the cache.
    ///
    /// The three failures are all "this is not nothing": a corrupt file, an item
    /// the app cannot render, and — the subtle one — a course **absent** from the
    /// map. The daemon omits a course whose routes failed and writes `[]` for one
    /// that genuinely has no work, so absent means "unknown". Answering `[]` to
    /// unknown would empty a submenu that was showing real work a minute ago;
    /// throwing folds to `.failed(lastKnown:)`, which keeps it.
    static func decode(_ bytes: Data, courseId: Int) throws -> [Assignment] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        } catch {
            throw CourseSourceError.malformedBody(String(describing: error))
        }
        guard let items = envelope.assignments[String(courseId)] else {
            throw CourseSourceError.transport("course \(courseId) is not in the daemon cache")
        }
        return try items.map { try $0.assignment(courseId: courseId) }
    }

    private struct Envelope: Decodable {
        let assignments: [String: [Item]]
    }

    /// One item as the Node fetcher writes it. `id` and `title` are
    /// non-optional, so an item missing either fails the decode — the same
    /// asymmetry `AssignmentParser` uses: a row with no id can never be clicked
    /// and a row with no name renders blank, while an unreadable *date* costs one
    /// line and is survivable.
    private struct Item: Decodable {
        let id: Int
        let title: String
        let dueDate: String?
        let kind: String

        func assignment(courseId: Int) throws -> Assignment {
            Assignment(
                id: self.id,
                courseId: courseId,
                name: self.title,
                dueDate: Self.parseDate(self.dueDate),
                // Neither field is in the daemon's contract. They land on the
                // neutral value rather than on a guess: a `true` here would hide
                // rows the moment a display policy starts reading it.
                isHidden: false,
                groupTypeId: nil,
                kind: try Self.parseKind(self.kind)
            )
        }

        /// `kind` decides which deep-link template a row opens, so an unrecognized
        /// one (a graded discussion, a checklist) may not default to `.assignment`
        /// — that renders a `db=` link to a page that does not exist, and looks
        /// completely normal doing it. Failing preserves the last known list until
        /// the Swift side learns the new kind.
        ///
        /// `"gradeOnly"` is one more accepted string, matched exactly, and not a
        /// looser rule: a prefix or case-insensitive match would wave through the
        /// near misses of a kind the daemon renamed, and strip the deadline off
        /// real work while pointing it at a gradebook.
        private static func parseKind(_ raw: String) throws -> ItemKind {
            switch raw {
            case "assignment": return .assignment
            case "quiz": return .quiz
            case "gradeOnly": return .gradeOnly
            default: throw CourseSourceError.malformedBody("unknown item kind \"\(raw)\"")
            }
        }

        /// The daemon normalizes to whole seconds today (`2026-09-15T23:59:00Z`),
        /// but D2L itself is not consistent about fractional seconds and a
        /// passthrough tomorrow must not cost a course its rows. Same two-attempt
        /// shape as `AssignmentParser`, for the same reason.
        private static func parseDate(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(raw, strategy: .iso8601))
        }
    }
}
