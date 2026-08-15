import Foundation

/// The `CourseSource` the app ships with: spawn the daemon, then read what it
/// wrote.
///
/// The app no longer fetches. `DaemonRunner` climbs nothing and knows nothing —
/// it runs `node src/refresh.mjs`, which owns the login ladder and the endpoints
/// — and this type turns the run into either `[Course]` or a typed failure. The
/// sandwich is exact: effect (spawn) → effect (read two files) → pure (decode).
///
/// Everything here defends one guarantee: **a failure must never look like an
/// empty course list.** `CourseCache.fold` replaces its contents on success and
/// preserves them on a thrown `CourseSourceError`, so the only way this source
/// can blank David's menu is by reporting success when it should have failed. A
/// daemon that exits 0 without writing a cache is therefore `.malformedBody`,
/// not zero courses; an exit 2 is `.sessionExpired`, not zero courses.
public struct DaemonCourseSource: CourseSource {

    private let runner: DaemonRunner

    public init(runner: DaemonRunner) {
        self.runner = runner
    }

    public func fetchCourses() async throws -> [Course] {
        let outcome = await self.runner.run()                                   // effect
        if let failure = Self.failure(for: outcome) { throw failure }           // pure
        // Belt and braces across two writers: the exit code and the status file
        // are two channels for one fact, and either alone must be enough.
        if let failure = DaemonCache.statusFailure(at: self.runner.paths) { throw failure }

        guard let bytes = DaemonCache.dataBytes(at: self.runner.paths) else {   // effect
            throw CourseSourceError.malformedBody("the daemon reported success but wrote no cache")
        }
        return try Self.decode(bytes)                                           // pure
    }

    // MARK: - Deciding

    /// How a run that did not produce a cache is reported.
    ///
    /// `.transport` for all three failures, because that is the taxonomy's
    /// "never reached the server" — a daemon that could not start, could not
    /// finish, or fell over never got an answer out of D2L either.
    static func failure(for outcome: DaemonOutcome) -> CourseSourceError? {
        switch outcome {
        case .ranOk: nil
        case .needsLogin: .sessionExpired
        case .failed(let detail): .transport(detail)
        case .timedOut: .transport("the daemon did not finish in time")
        case .spawnFailed(let detail): .transport("the daemon could not be started: \(detail)")
        }
    }

    /// The courses half of `data.json`. Unknown keys are ignored — the daemon
    /// will grow fields — but a missing `courses` key, or a course missing one of
    /// its own, fails loudly: valid JSON of the wrong shape is exactly the drift
    /// a two-language boundary produces, and silence would cost the whole menu.
    static func decode(_ bytes: Data) throws -> [Course] {
        do {
            return try JSONDecoder().decode(Envelope.self, from: bytes).courses
        } catch {
            throw CourseSourceError.malformedBody(String(describing: error))
        }
    }

    private struct Envelope: Decodable {
        let courses: [Course]
    }
}
