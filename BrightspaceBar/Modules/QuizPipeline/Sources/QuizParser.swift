import Foundation
import AssignmentPipeline
import CoursePipeline

/// Decodes D2L's `quizzes/` payload into `[Assignment]` stamped `kind: .quiz`.
///
/// Pure functional core: `Data` plus the course it was fetched for in, values out,
/// or a typed `CourseSourceError`. No I/O, no clock, no state.
///
/// The failure taxonomy is the point of this file, and it is dictated by what happens
/// downstream: `AssignmentStore` maps success to "replace" and failure to "preserve".
/// So answering "success, zero quizzes" to a bad body does not merely show an empty
/// section — it **discards the quizzes the user had**.
///
/// **The envelope is the sharpest instance, and it is structural rather than
/// hypothetical.** Quizzes arrive as `{"Objects": [...], "Next": …}`; the sibling
/// `dropbox/folders` route returns a **bare array**. A decoder copy-pasted from
/// `AssignmentParser` would decode the real envelope to zero items and report
/// success. `Envelope.objects` is therefore non-optional, so a bare array fails the
/// decode and is classified as a failure — see
/// `theAssignmentShapeIsNotSilentlyAccepted`.
///
/// - `{"Objects": [...]}`                      → `[Assignment]` in server order
/// - `{"Objects": []}`                         → `[]` (no quizzes is data, not an error)
/// - a bare JSON array                         → `.malformedBody`
/// - the HTTP-200 session stub                 → `.sessionExpired`
/// - anything else                             → `.malformedBody`
/// - an item with no `QuizId` or no `Name`      → `.malformedBody`
/// - an item with an unparseable `DueDate`      → kept, with `dueDate == nil`
///
/// The asymmetry in that last pair matches `AssignmentParser` exactly. A missing id
/// or name is **fatal to the course**: without an id the row can never be clicked,
/// without a name it renders blank. An unparseable *date* is **survivable**: it costs
/// one missing line, whereas throwing would cost every quiz in the course and freeze
/// the menu behind a date-format change.
public enum QuizParser {

    public static func parse(_ data: Data, courseId: Int) throws -> [Assignment] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            // Not the quiz envelope. Classify before giving up: the same dead cookie
            // that reaches this route answers the token mint with HTTP 200 and an
            // HTML stub redirecting to `/d2l/login?sessionExpired=1`. Keying on that
            // exact marker — and only after the decode has already failed — means
            // generic HTML (a 502 page, an outage banner) stays `.malformedBody`
            // instead of dragging the user through a pointless re-login.
            if String(decoding: data, as: UTF8.self).contains("sessionExpired=1") {
                throw CourseSourceError.sessionExpired
            }
            throw CourseSourceError.malformedBody(String(describing: error))
        }

        return envelope.objects.map { $0.item(courseId: courseId) }
    }
}

// MARK: - Wire shape (private — D2L's raw field names never escape this file)

/// The paged envelope. `Objects` is non-optional so the bare-array shape cannot
/// decode; `Next` is not modelled at all, because every observed course returned
/// `null` and a course has a handful of quizzes rather than a page's worth.
private struct Envelope: Decodable {
    let objects: [Quiz]

    enum CodingKeys: String, CodingKey {
        case objects = "Objects"
    }
}

/// One quiz. The live payload carries **37 keys**; only four are modelled, and the
/// other 33 are deliberately ignored rather than absorbed into optional properties.
///
/// That is a correctness rule, not laziness. Only `QuizId`, `Name`, `DueDate` and
/// `IsActive` were captured *with their values*; the remaining 33 were captured as
/// names only, so their shapes are unverified. Modelling one would make the whole
/// course fail to decode the moment a guess turned out wrong — which has already
/// happened twice on the assignments route (`Availability` is `null` itself rather
/// than an object; `ActivityId` is a String, not an Int) and once in the third-party
/// `brightspace-mcp-server`, whose interface declares a `TimeLimit` field this tenant
/// does not send.
///
/// `QuizId` and `Name` are non-optional so a payload missing either fails the decode,
/// which `parse` reports as `.malformedBody`.
private struct Quiz: Decodable {
    let id: Int
    let name: String
    let dueDate: String?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "QuizId"
        case name = "Name"
        case dueDate = "DueDate"
        case isActive = "IsActive"
    }

    /// Faithful preservation, plus the two things the payload cannot supply: the
    /// course id, stamped from the request, and the kind.
    func item(courseId: Int) -> Assignment {
        Assignment(
            id: self.id,
            courseId: courseId,
            name: self.name,
            dueDate: Self.parseDate(self.dueDate),
            // `IsActive: false` is D2L's own "not available to students" — the quiz
            // analogue of a dropbox folder's `IsHidden`. Mapping it onto the SAME
            // field means one visibility policy covers both kinds and the
            // translation layer needs no per-kind branch. An absent flag counts as
            // active, for the same reason `AssignmentParser` treats an absent
            // `IsHidden` as visible: a missing flag should not cost a row.
            isHidden: !(self.isActive ?? true),
            // Quizzes have no group concept and their deep link has no group
            // parameter. Leaving this nil keeps the two link templates from bleeding
            // into each other.
            groupTypeId: nil,
            kind: .quiz
        )
    }

    /// D2L sends `2026-03-01T04:59:00.000Z`, and is not consistent about the
    /// fractional seconds — `2026-09-15T23:59:00Z` also occurs. `ISO8601FormatStyle`
    /// is strict about them, so both forms are tried. This codebase has been bitten
    /// twice by a parser that accepted only one (see `MenuTranslation.parseDate` and
    /// `AssignmentParser`), which is why the same two-attempt shape is repeated here
    /// rather than assumed away.
    ///
    /// Anything else yields nil — the fail-open half of the taxonomy above.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601))
    }
}
