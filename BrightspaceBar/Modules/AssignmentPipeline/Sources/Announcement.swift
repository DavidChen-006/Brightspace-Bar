import Foundation
import CoursePipeline

/// One announcement (D2L "news item"), as the backend holds it.
///
/// Deliberately the same shape discipline as `Assignment`: `id` and `title` are
/// non-optional — a row with no id can never be keyed and a row with no title
/// renders blank — while a missing *date* costs the row its cutoff eligibility
/// and nothing else.
public struct Announcement: Equatable, Sendable, Identifiable {
    /// D2L news item id, unique within a course.
    public let id: Int
    /// The course this announcement belongs to.
    public let courseId: Int
    /// The announcement's title, verbatim.
    public let title: String
    /// When it was posted (D2L `StartDate`, falling back to `CreatedDate` on the
    /// daemon side). Nil means D2L sent neither.
    public let date: Date?

    public init(id: Int, courseId: Int, title: String, date: Date? = nil) {
        self.id = id
        self.courseId = courseId
        self.title = title
        self.date = date
    }
}

/// Anything that can produce one course's announcements. Mirrors
/// `AssignmentSource` exactly, and for the same reason: a scriptable fake and
/// the real cache reader both implement it, so the pipeline is testable without
/// a daemon run.
public protocol AnnouncementSource: Sendable {
    func fetchAnnouncements(courseId: Int) async throws -> [Announcement]
}

/// What is known about one course's announcements. The same three-case shape as
/// `AssignmentsState`, kept distinct for the same load-bearing reasons: a course
/// that has not loaded yet must not claim to have no announcements, and a dead
/// session must not silently empty a section that was showing real ones.
public enum AnnouncementsState: Equatable, Sendable {
    /// No fetch has been attempted. The state at launch.
    case neverFetched
    /// A fetch succeeded. An empty array here is *data*: the course genuinely
    /// has no announcements.
    case loaded([Announcement])
    /// A fetch failed. `lastKnown` is whatever was loaded before — possibly
    /// empty, if the very first fetch failed.
    case failed(lastKnown: [Announcement], error: CourseSourceError)

    /// The best available list, whatever the state.
    public var announcements: [Announcement] {
        switch self {
        case .neverFetched: []
        case .loaded(let announcements): announcements
        case .failed(let lastKnown, _): lastKnown
        }
    }
}

/// The click target for every announcement row: the course's announcements
/// page. Derived uniformly from the course id — one rule for every row, the
/// same policy `MenuTranslation.url` follows for courses — because D2L offers
/// no stable per-item deep link worth trusting across tenants.
public enum AnnouncementLink {
    public static func url(courseId: Int, baseURL: URL) -> URL {
        // `appending(path:)` normalises the joining slash; the query survives
        // as an explicit component.
        var components = URLComponents(
            url: baseURL.appending(path: "d2l/lms/news/main.d2l"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "ou", value: String(courseId))]
        return components.url!
    }
}
