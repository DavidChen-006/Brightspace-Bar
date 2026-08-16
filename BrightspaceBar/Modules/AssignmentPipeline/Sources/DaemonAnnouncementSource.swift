import Foundation
import CoursePipeline

/// The `AnnouncementSource` the app ships with: one course's announcements, read
/// out of the same cache the assignments come from.
///
/// It takes paths and **no runner**, so it structurally cannot spawn anything —
/// the same cost argument `DaemonAssignmentSource` makes, and it gets sharper
/// with a second section: the app now asks two questions per visible course, and
/// both answers were already in the one `data.json` the daemon wrote.
///
/// Reading it as a separate source rather than widening the assignment one is
/// deliberate. The two sections fail independently on the daemon's side — a
/// course whose news route 403s still has assignments, and vice versa — so they
/// fold independently here too. A single source returning both would have to
/// pick one failure to report.
///
/// The mapping is the risk. The wire shape is three fields where the model has
/// four: `courseId` is not in the payload at all (the map key carries it) and
/// `date` is a string that may be null. Nothing in either language checks the
/// other, so those are the places a silent wrong answer appears.
public struct DaemonAnnouncementSource: AnnouncementSource {

    private let paths: DaemonPaths

    public init(paths: DaemonPaths) {
        self.paths = paths
    }

    public func fetchAnnouncements(courseId: Int) async throws -> [Announcement] {
        if let failure = DaemonCache.statusFailure(at: self.paths) { throw failure }
        guard let bytes = DaemonCache.dataBytes(at: self.paths) else {          // effect
            throw CourseSourceError.transport("no daemon cache has been written yet")
        }
        return try Self.decode(bytes, courseId: courseId)                       // pure
    }

    // MARK: - Deciding: the wire shape becomes the model

    /// One course's announcements out of the cache.
    ///
    /// The failures are the assignment source's, with one addition. A course
    /// **absent** from the map means "unknown": the daemon omits a course whose
    /// news route failed and writes `[]` for one that answered with nothing, and
    /// answering `[]` to unknown would empty a section that was showing real
    /// posts a minute ago. Throwing folds to `.failed(lastKnown:)`, which keeps
    /// them.
    ///
    /// The addition is that the whole `announcements` field is optional. Every
    /// install has a cache without it between the app updating and the next
    /// daemon run landing, and that file is not corrupt — it has simply never
    /// been asked. Missing therefore collapses into the same "unknown" answer an
    /// absent course gets, rather than into `malformedBody`, which would report
    /// damage to a perfectly good cache.
    static func decode(_ bytes: Data, courseId: Int) throws -> [Announcement] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        } catch {
            throw CourseSourceError.malformedBody(String(describing: error))
        }
        guard let items = envelope.announcements?[String(courseId)] else {
            throw CourseSourceError.transport("course \(courseId) is not in the daemon cache")
        }
        return items.map { $0.announcement(courseId: courseId) }
    }

    private struct Envelope: Decodable {
        let announcements: [String: [Item]]?
    }

    /// One announcement as the Node fetcher writes it. `id` and `title` are
    /// non-optional, so an item missing either fails the decode — the same
    /// asymmetry every parser in this package uses: a row with no id can never be
    /// keyed and a row with no title renders blank, while an unreadable *date*
    /// costs one line and is survivable.
    private struct Item: Decodable {
        let id: Int
        let title: String
        let date: String?

        func announcement(courseId: Int) -> Announcement {
            Announcement(
                id: self.id,
                courseId: courseId,
                title: self.title,
                date: Self.parseDate(self.date)
            )
        }

        /// The daemon normalizes to whole seconds today (`2026-08-10T16:34:00Z`),
        /// but D2L itself is not consistent about fractional seconds and a
        /// passthrough tomorrow must not cost a course its announcements. Same
        /// two-attempt shape as `DaemonAssignmentSource`, for the same reason.
        private static func parseDate(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(raw, strategy: .iso8601))
        }
    }
}
