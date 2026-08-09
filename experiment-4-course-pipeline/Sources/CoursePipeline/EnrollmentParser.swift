import Foundation

/// Decodes D2L's `myenrollments` payload into `[Course]`.
///
/// Pure functional core: `Data` in, `[Course]` out, or a typed
/// `CourseSourceError`. No I/O, no clock, no state.
///
/// Failure taxonomy — the whole point of this module. Downstream, the cache
/// maps `.success([])` to "rewrite the file" but `.failure` to "preserve stale
/// data", so misclassifying a failure as an empty success wipes a good cache:
///
/// - the token mint's HTTP-200 session stub    → `.sessionExpired`
/// - anything else that is not the envelope    → `.malformedBody`
/// - `{"Items":[]}`                            → `[]` (no enrollments is data, not an error)
/// - an undecodable item among decodable ones  → skipped
/// - a non-empty `Items` where nothing decodes → `.malformedBody` (the backstop)
public struct EnrollmentParser: Sendable {

    public init() {}

    public func parse(_ data: Data) throws -> [Course] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            // Not the enrollment envelope. Classify before giving up: the token
            // mint answers a dead session with HTTP 200 plus an HTML stub whose
            // script redirects to `/d2l/login?sessionExpired=1&…`. Key on that
            // exact marker — generic HTML (a 502 page, an unrelated redirect)
            // must stay `.malformedBody`, or every outage would be misread as an
            // auth failure and drag the user through a pointless re-login.
            // Checking only after the decode fails means a genuine payload that
            // merely mentions the marker can never be misclassified.
            if String(decoding: data, as: UTF8.self).contains("sessionExpired=1") {
                throw CourseSourceError.sessionExpired
            }
            throw CourseSourceError.malformedBody(String(describing: error))
        }

        let courses = envelope.items.compactMap { $0.value?.course }

        // The backstop that makes per-item skipping safe: D2L said "here are N
        // enrollments"; if none of them decoded, that is a shape mismatch to
        // report, not an account with no courses. Without this, a fully broken
        // payload would degrade into a silent empty list — exactly the bug the
        // taxonomy above exists to prevent.
        if courses.isEmpty && !envelope.items.isEmpty {
            throw CourseSourceError.malformedBody(
                "none of \(envelope.items.count) items was decodable"
            )
        }

        return courses
    }
}

// MARK: - Wire shape (private — D2L's raw field names never escape this file)

/// Top level: `{"PagingInfo":…,"Items":[…]}`. `Items` is the only key needed;
/// Codable ignores unknown keys, which is the forward compatibility the SPEC
/// requires (the real fixture already carries five keys `Course` does not model,
/// and D2L adds more without warning).
private struct Envelope: Decodable {
    let items: [Failable<Item>]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

/// Decodes `T` if it can, `nil` if it cannot — the per-item skip. Absorbing the
/// error here rather than failing the whole array is what lets one org unit
/// mid-deletion cost one menu row instead of all 27.
private struct Failable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) {
        self.value = try? T(from: decoder)
    }
}

private struct Item: Decodable {
    let orgUnit: OrgUnit
    let access: Access

    enum CodingKeys: String, CodingKey {
        case orgUnit = "OrgUnit"
        case access = "Access"
    }

    /// Faithful preservation: every field verbatim, nulls included. `HomeUrl`
    /// is null in 25 of 27 real items — deriving `{base}/d2l/home/{id}` is a
    /// click-layer policy decision, deliberately not made here.
    var course: Course {
        Course(
            id: self.orgUnit.id,
            name: self.orgUnit.name,
            code: self.orgUnit.code,
            role: self.access.role,
            isActive: self.access.isActive,
            homeUrl: self.orgUnit.homeUrl,
            startDate: self.access.startDate,
            endDate: self.access.endDate
        )
    }
}

private struct OrgUnit: Decodable {
    let id: Int
    let name: String
    let code: String
    let homeUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case code = "Code"
        case homeUrl = "HomeUrl"
    }
}

private struct Access: Decodable {
    let isActive: Bool
    let startDate: String?
    let endDate: String?
    let role: String

    enum CodingKeys: String, CodingKey {
        case isActive = "IsActive"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case role = "ClasslistRoleName"
    }
}
