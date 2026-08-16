import Foundation
import Testing
import CoursePipeline
import AssignmentPipeline

// ═════════════════════════════════════════════════════════════════════════════
// THE THIRD KIND ON THE WIRE — `"gradeOnly"` → `ItemKind.gradeOnly`.
//
// A gradebook column that matches no fetched assignment or quiz is the only
// shadow some graded work casts before it becomes visible anywhere else. The
// daemon now writes those columns into the same per-course item list as a third
// `kind`, with `dueDate` ALWAYS null in v1.
//
// PRIORITY: the widening must admit exactly one new string. `parseKind` is the
// gate that decides which of three deep-link templates a row opens, and it is
// the reason an unknown kind fails the whole course rather than defaulting to
// `.assignment` — a `db=` link built for a gradebook column is a well-formed URL
// for a dropbox folder that does not exist, and it looks completely normal doing
// it. The failure this feature newly makes possible is a gate widened too far:
// a prefix match, a case-insensitive match, or a `default: .gradeOnly` would all
// pass a test that only ever feeds it the happy string.
//
// CULLED: everything `DaemonAssignmentSourceTests` already pins — the envelope,
// the course-id stamping, the absent-course rule, the status file, the spawn
// count. None of that changes with a third kind, and re-asserting it here would
// just be a second place to update. `anUnknownKindIsFatal` already covers
// "discussion"; what is NEW is the near misses of the string being added.
//
// SCOPE: small. A canned cache in a temp `BSB_ROOT`, no process, no network.
// ═════════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// PINNED POLICY — the builder implements exactly this.
//
//   public enum ItemKind { case assignment, quiz, gradeOnly }
//
//   parseKind("assignment") → .assignment      (unchanged)
//   parseKind("quiz")       → .quiz            (unchanged)
//   parseKind("gradeOnly")  → .gradeOnly       (new — exact string, exact case)
//   anything else           → throws .malformedBody   (UNCHANGED — one more
//                                                      accepted string, not a
//                                                      looser rule)
//
// A `gradeOnly` item arrives with `dueDate: null` and stays nil. Nothing here
// interprets that: the null is preserved the same way every other null due date
// is, and the "no due date" WORDING is the translation layer's job, not the
// decoder's.
// ─────────────────────────────────────────────────────────────────────────────

private let scholarly = 440_703

/// The wire shape of one heads-up column, exactly as LADDER-PLAN's contract
/// writes it: a `GradeObjectId`, the column's `Name` as `title`, a null date, and
/// the precomputed gradebook URL that Swift ignores in favour of its own.
private func gradeOnlyItem(id: Int, title: String, dueDate: String = "null") -> String {
    """
    { "id": \(id), "title": "\(title)", "dueDate": \(dueDate),
      "url": "https://purdue.brightspace.com/d2l/lms/grades/my_grades/main.d2l?ou=440703",
      "kind": "gradeOnly" }
    """
}

@Suite("DaemonAssignmentSource — the gradeOnly kind")
struct GradeOnlyDecodeTests {

    @Test("a gradeOnly column decodes into an item stamped .gradeOnly")
    func gradeOnlyKeepsItsKind() async throws {
        // Arrange — the Civics probe case: a column scored in the gradebook whose
        // assignment is hidden or release-gated, so no content route ever returns
        // it. `title` on the wire is `name` in the model, exactly as for the two
        // kinds that shipped.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem(gradeOnlyItem(id: 812_004, title: "Participation")),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.map(\.kind) == [.gradeOnly])
        #expect(items.map(\.name) == ["Participation"])
        #expect(items.map(\.id) == [812_004])
    }

    @Test("a gradeOnly column has no due date, and nothing invents one")
    func gradeOnlyCarriesNoDueDate() async throws {
        // Arrange — `dueDate` is ALWAYS null for this kind in v1; the date ladder
        // is a Fall decision to be made from logged real column names. An epoch or
        // a sentinel here would render as a deadline that does not exist.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem(gradeOnlyItem(id: 812_004, title: "Participation")),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.first?.dueDate == nil)
    }

    @Test("all three kinds in one course each keep their own, in the daemon's order")
    func threeKindsSurviveOneList() async throws {
        // Arrange — assignments, then quizzes, then the gradebook diff, which is
        // the order the fetcher merges them in. That order is load-bearing:
        // `MenuModel` is `Equatable` and drives the skip-rebuild, so a list that
        // reshuffled between refreshes would repaint the menu forever. Interleaved
        // ids so a positional bug yields a wrong kind rather than a lucky one.
        let world = DaemonWorld()
        world.seedCache(
            data: DaemonJSON.oneItem("""
                { "id": 445296, "title": "Upload your CITI Certificate", "dueDate": null,
                  "url": "https://purdue.brightspace.com/x", "kind": "assignment" },
                { "id": 700001, "title": "Syllabus Quiz", "dueDate": null,
                  "url": "https://purdue.brightspace.com/y", "kind": "quiz" },
                \(gradeOnlyItem(id: 812_004, title: "Participation"))
                """),
            status: DaemonJSON.freshStatus
        )

        // Act
        let items = try await world.assignmentSource().fetchAssignments(courseId: scholarly)

        // Assert
        #expect(items.map(\.kind) == [.assignment, .quiz, .gradeOnly])
        #expect(items.map(\.id) == [445_296, 700_001, 812_004])
    }

    @Test("a near miss of gradeOnly still fails the course rather than being waved through")
    func nearMissKindsAreStillFatal() async {
        // Arrange — the failure THIS change newly makes possible. `"gradeonly"`
        // passes a case-insensitive match, `"grade"` passes a prefix match, and
        // `"gradeOnlyItem"` passes a `hasPrefix`. All three would then open a
        // gradebook link for something that is not a gradebook column — or, worse,
        // a `default:` that fell through to `.gradeOnly` would silently strip the
        // deadline off a real assignment whose kind the daemon renamed.
        for raw in ["gradeonly", "GRADEONLY", "grade", "gradeOnlyItem", "gradesOnly"] {
            let world = DaemonWorld()
            world.seedCache(
                data: DaemonJSON.oneItem("""
                    { "id": 1, "title": "Participation", "dueDate": null,
                      "url": "https://purdue.brightspace.com/x", "kind": "\(raw)" }
                    """),
                status: DaemonJSON.freshStatus
            )

            // Act
            let error = await courseSourceError {
                _ = try await world.assignmentSource().fetchAssignments(courseId: scholarly)
            }

            // Assert — the existing rule, untouched: one more accepted string, not
            // a looser gate.
            #expect(error?.isMalformedBody == true, "kind \"\(raw)\" gave \(String(describing: error))")
        }
    }
}
