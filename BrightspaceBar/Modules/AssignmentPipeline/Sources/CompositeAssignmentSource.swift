import Foundation
import CoursePipeline

/// One `AssignmentSource` built from several, so a course's work can come from more
/// than one D2L route without anything downstream knowing.
///
/// This is where the two-ness of assignments-and-quizzes is hidden. It conforms to
/// the *existing* `AssignmentSource`, so `AssignmentFetcher`, `AssignmentStore` and
/// `AssignmentsState` are reused untouched — from their side nothing changed, and
/// one course still has one state holding one list. The alternative, a parallel
/// quiz store and fetcher, would mean two folds to keep in sync, two orphan-cleanup
/// rules, and a course whose assignments succeeded while its quizzes failed sitting
/// in two contradictory states.
///
/// Three decisions this type makes so no caller has to:
///
/// - **Partial failure returns what it got.** One request per course became two, so
///   a failing quiz route would otherwise discard the assignments that were just
///   fetched successfully — a shipped feature regressed by adding a new one. The
///   cost is that a partial failure is invisible to the store; that is accepted,
///   because the store's job is to protect data and half the data is strictly
///   better than none.
/// - **Total failure throws the FIRST source's error**, in source order. Not a
///   combined error: keeping the existing `CourseSourceError` taxonomy intact is
///   what lets `.sessionExpired` still reach the store meaningfully. Source order
///   makes the choice deterministic rather than a race.
/// - **Merge order is source order**, never completion order. `MenuModel`'s
///   `Equatable` drives the GUI's skip-rebuild, so output whose order depended on
///   which request finished first would make identical data compare unequal between
///   refreshes.
public struct CompositeAssignmentSource: AssignmentSource {

    private let sources: [any AssignmentSource]

    public init(sources: [any AssignmentSource]) {
        self.sources = sources
    }

    // MARK: - Shell: ask every source at once

    public func fetchAssignments(courseId: Int) async throws -> [Assignment] {
        let results = await self.fetchAll(courseId: courseId)   // effects
        return try Self.merge(results)                          // pure
    }

    /// Every source's answer, in source order, with every throw already converted to
    /// a value.
    ///
    /// A **non-throwing** group is the mechanism that keeps one source's failure from
    /// losing another's items: with no error to propagate there is nothing to cancel
    /// the siblings with. Same shape as `AssignmentFetcher.fetchAll`, for the same
    /// reason — the fan-out there is over courses, here over routes.
    private func fetchAll(courseId: Int) async -> [Result<[Assignment], CourseSourceError>] {
        await withTaskGroup(
            of: (index: Int, result: Result<[Assignment], CourseSourceError>).self
        ) { group in
            for (index, source) in self.sources.enumerated() {
                group.addTask {
                    (index, await Self.fetch(courseId: courseId, from: source))
                }
            }
            var collected: [(index: Int, result: Result<[Assignment], CourseSourceError>)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            // Children finish in whatever order the network allows; the index puts
            // them back into source order before anything reads them.
            return collected.sorted { $0.index < $1.index }.map(\.result)
        }
    }

    /// One source's fetch. An untyped error becoming `.transport` matches
    /// `AssignmentFetcher` and `Poller`: the store only folds `CourseSourceError`,
    /// and an unclassifiable failure is still a failure.
    private static func fetch(
        courseId: Int,
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

    // MARK: - Deciding: what a mix of successes and failures means

    /// Successes concatenated in source order — unless *nothing* succeeded, in which
    /// case the first failure is thrown.
    ///
    /// The distinction is the whole point. "Every route failed" must not read as
    /// "success, no work", which would make the store replace real data with nothing;
    /// "one route failed" must not read as total failure, which would make it discard
    /// the other route's fresh data. No sources at all is empty, not an error: a build
    /// that disables a kind is degenerate but not broken.
    private static func merge(
        _ results: [Result<[Assignment], CourseSourceError>]
    ) throws -> [Assignment] {
        var items: [Assignment] = []
        var succeeded = false
        var firstFailure: CourseSourceError?

        for result in results {
            switch result {
            case .success(let fetched):
                succeeded = true
                items += fetched
            case .failure(let error):
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure, !succeeded { throw firstFailure }
        return items
    }
}
