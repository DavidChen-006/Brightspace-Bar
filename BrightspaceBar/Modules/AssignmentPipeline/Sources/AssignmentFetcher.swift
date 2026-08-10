import Foundation
import CoursePipeline

/// Fans one request out per course and folds every answer into the store.
///
/// The imperative shell of the assignment pipeline, and the whole backend vertical
/// in one call:
///
///     [Course]  →  N parallel GETs  →  parse  →  per-course fold
///
/// It owns no decision logic. Which courses to ask about is the caller's call (the
/// currentness filter upstream has already narrowed 27 enrolled courses to the
/// handful in session); what survives a failure belongs to `AssignmentStore`; how
/// to build a click target belongs to `AssignmentLink`.
///
/// The decisions this module hides from its callers:
/// - **Errors are values.** `refresh` does not throw. A failing course surfaces as
///   `.preservedStale(error)` in the returned map, exactly what the store reports
///   when it keeps the old list, so one dead course reads the same as any other
///   non-update.
/// - **A failure cannot cancel its siblings.** This is the specific bug a throwing
///   `TaskGroup` produces: the first child error cancels the rest, so a single
///   403 costs you every other course's assignments. Each child therefore
///   converts its own throw into a `Result` and the group never throws.
/// - **Cleanup is implied by the course list.** Courses absent from `courses` are
///   forgotten, so a dropped class cannot linger. The caller cannot forget to ask.
/// - **No explicit concurrency cap.** `URLSession` already limits connections per
///   host (6 by default on macOS), so a cap here would be a second, redundant
///   throttle to keep in sync — and N is the number of courses a student is
///   actually taking.
public struct AssignmentFetcher: Sendable {
    private let source: any AssignmentSource
    private let store: AssignmentStore

    public init(source: any AssignmentSource, store: AssignmentStore) {
        self.source = source
        self.store = store
    }

    /// Refresh assignments for exactly these courses, and forget all others.
    ///
    /// - Returns: one `CacheOutcome` per course passed in. A missing key would be a
    ///   course whose result was silently dropped, so every course gets an entry.
    public func refresh(courses: [Course]) async -> [Int: CacheOutcome] {
        // Cleanup first, and unconditionally — an empty course list is the
        // semester-break case and must still forget last term's assignments.
        await self.store.retain(courseIds: Set(courses.map(\.id)))
        guard !courses.isEmpty else { return [:] }

        let results = await self.fetchAll(courses)

        // Folding after the fan-out, rather than inside each child, keeps the
        // store's decisions sequential and the outcome map deterministic even
        // though the requests themselves overlap.
        var outcomes: [Int: CacheOutcome] = [:]
        for (courseId, result) in results {
            outcomes[courseId] = await self.store.apply(courseId: courseId, result: result)
        }
        return outcomes
    }

    /// The parallel half. A **non-throwing** group whose children return `Result`
    /// is what makes a failure local: there is no error to propagate, so there is
    /// nothing to cancel the siblings with.
    private func fetchAll(
        _ courses: [Course]
    ) async -> [(courseId: Int, result: Result<[Assignment], CourseSourceError>)] {
        let source = self.source
        return await withTaskGroup(
            of: (courseId: Int, result: Result<[Assignment], CourseSourceError>).self
        ) { group in
            for course in courses {
                group.addTask {
                    (course.id, await Self.fetch(course.id, from: source))
                }
            }
            var collected: [(courseId: Int, result: Result<[Assignment], CourseSourceError>)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
    }

    /// One course's fetch, with every throw converted to a typed value.
    ///
    /// An untyped error becoming `.transport` matches `Poller`'s handling: the
    /// store only knows how to fold `CourseSourceError`, and an unclassifiable
    /// failure is still a failure that must preserve data rather than escape.
    private static func fetch(
        _ courseId: Int,
        from source: any AssignmentSource
    ) async -> Result<[Assignment], CourseSourceError> {
        do {
            return .success(try await source.fetchAssignments(courseId: courseId))
        } catch let error as CourseSourceError {
            return .failure(error)
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }
}
