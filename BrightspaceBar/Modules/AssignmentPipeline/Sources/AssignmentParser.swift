import Foundation
import CoursePipeline

/// Decodes D2L's `dropbox/folders` payload into `[Assignment]`.
///
/// Pure functional core: `Data` plus the course it was fetched for in, values out,
/// or a typed `CourseSourceError`. No I/O, no clock, no state.
///
/// The failure taxonomy is the point of this file, and it is dictated by what
/// happens downstream: `AssignmentStore` maps success to "replace" and failure to
/// "preserve". So answering "success, zero assignments" to an error body does not
/// merely show an empty submenu — it **discards the assignments the user had**.
/// Every classification below exists to keep failures classified as failures.
///
/// - a bare JSON array                     → `[Assignment]` in server order
/// - `[]`                                  → `[]` (no assignments is data, not an error)
/// - the HTTP-200 session stub             → `.sessionExpired`
/// - anything else that is not an array    → `.malformedBody`
/// - an item with no `Id` or no `Name`     → `.malformedBody`
/// - an item with an unparseable `DueDate` → kept, with `dueDate == nil`
///
/// Note the deliberate asymmetry in that last pair. A missing id or name is
/// **fatal to the course**: without an id the row can never be clicked, and
/// without a name it renders blank, so the honest answer is to fail the fetch and
/// let the store preserve good data. An unparseable *date* is **survivable**: it
/// costs one missing line, whereas throwing would cost every assignment in the
/// course and freeze the menu behind a date-format change. Fail closed where the
/// row is unusable, fail open where only a detail is.
///
/// This is also why there is no per-item skipping here, unlike `EnrollmentParser`.
/// That parser skips undecodable enrollments because one org unit mid-deletion
/// should cost one row out of 27. Here a malformed item means the shape assumption
/// is wrong, and a course has a handful of assignments rather than dozens, so
/// silently serving a subset would be indistinguishable from an instructor having
/// deleted the rest.
public enum AssignmentParser {

    public static func parse(_ data: Data, courseId: Int) throws -> [Assignment] {
        let folders: [Folder]
        do {
            folders = try JSONDecoder().decode([Folder].self, from: data)
        } catch {
            // Not the folder array. Classify before giving up: the same dead
            // cookie that reaches this route answers the token mint with HTTP 200
            // and an HTML stub redirecting to `/d2l/login?sessionExpired=1`.
            // Keying on that exact marker — and only after the decode has already
            // failed — means generic HTML (a 502 page, an outage banner) stays
            // `.malformedBody` instead of dragging the user through a pointless
            // re-login, and a genuine payload that merely mentions the marker can
            // never be misclassified.
            if String(decoding: data, as: UTF8.self).contains("sessionExpired=1") {
                throw CourseSourceError.sessionExpired
            }
            throw CourseSourceError.malformedBody(String(describing: error))
        }

        return try folders.map { try $0.assignment(courseId: courseId) }
    }
}

// MARK: - Wire shape (private — D2L's raw field names never escape this file)

/// One dropbox folder. The live payload carries 28 keys; only four are modelled.
/// `Codable` ignores the rest, which is the forward compatibility this tenant
/// demands — and which quietly absorbs three measured landmines:
///
/// - `Availability` is **`null` itself**, not an object with null members. A
///   struct declared for it would fail to decode every real folder.
/// - `ActivityId` is a **String** (`https://ids.brightspace.com/activities/...`),
///   not an Int.
/// - `TotalFiles`, `TotalUsers` and the other counters are all `-1` for a
///   student — instructor-facing, and meaningless here.
///
/// `Id` and `Name` are non-optional so a payload missing either fails the decode,
/// which `parse` reports as `.malformedBody`.
private struct Folder: Decodable {
    let id: Int
    let name: String
    let dueDate: String?
    let isHidden: Bool?
    let groupTypeId: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case dueDate = "DueDate"
        case isHidden = "IsHidden"
        case groupTypeId = "GroupTypeId"
    }

    /// Faithful preservation, plus the one thing the payload cannot supply: the
    /// course id, stamped from the request.
    ///
    /// Throwing is reserved for the fields whose absence makes a row unusable —
    /// and both of those already failed at decode time — so this cannot currently
    /// throw. It stays `throws` because it is the right place for any future
    /// field-level validation, and callers already handle it.
    func assignment(courseId: Int) throws -> Assignment {
        Assignment(
            id: self.id,
            courseId: courseId,
            name: self.name,
            dueDate: Self.parseDate(self.dueDate),
            // Absent `IsHidden` is treated as visible rather than as a decode
            // failure: hiding is not this module's decision, and a missing flag
            // should not cost the whole course.
            isHidden: self.isHidden ?? false,
            groupTypeId: self.groupTypeId
        )
    }

    /// D2L sends `2026-03-01T04:59:00.000Z`, and is not consistent about the
    /// fractional seconds — `2026-09-15T23:59:00Z` also occurs. `ISO8601FormatStyle`
    /// is strict about them, so both forms are tried. This codebase has already
    /// been bitten once by a parser that accepted only one (see
    /// `MenuTranslation.parseDate`), which is why the same two-attempt shape is
    /// repeated here rather than being assumed away.
    ///
    /// Anything else yields nil — the fail-open half of the taxonomy above.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601))
    }
}
