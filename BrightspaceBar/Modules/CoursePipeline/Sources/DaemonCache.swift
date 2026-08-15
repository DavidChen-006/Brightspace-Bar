import Foundation

/// The two files a daemon run leaves under `cache/`, as the app reads them.
///
/// Both sources — courses here, assignments in `AssignmentPipeline` — read the
/// same `data.json` and the same `status.json`, so the *reading* lives once, in
/// one place, and each source decodes only its own half of the payload. Every
/// read is fresh: a daemon run that lands while the app is up takes effect on
/// the next fetch, with no relaunch (the `FileSessionProvider` precedent).
public enum DaemonCache {

    /// The failure `status.json` reports, or nil when it reports none.
    ///
    /// A missing or corrupt status file is **tolerated**, matching the rule the
    /// daemon already applies on the writing side: the data file is the payload,
    /// the status file is only the report. An unrecognized state is tolerated for
    /// the same reason unknown JSON keys are — the daemon will grow states, and a
    /// Swift side that failed on them would make every daemon release a breaking
    /// one.
    public static func statusFailure(at paths: DaemonPaths) -> CourseSourceError? {
        guard
            let bytes = try? Data(contentsOf: paths.statusFile),
            let status = try? JSONDecoder().decode(Status.self, from: bytes)
        else {
            return nil
        }
        switch status.state {
        // The ladder ran out. `.sessionExpired` folds to `.preservedStale`, which
        // is what keeps courses on screen while David logs back in.
        case "needs-login": return .sessionExpired
        case "error": return .transport(status.error ?? "the daemon reported an error")
        default: return nil
        }
    }

    /// The bytes of `data.json`, or nil when there is no readable file.
    ///
    /// What nil *means* is the caller's to decide, and the two callers disagree
    /// honestly: after a run that claimed success it is a broken contract, while
    /// to an assignment fetch that spawned nothing it is simply a daemon that has
    /// never run.
    public static func dataBytes(at paths: DaemonPaths) -> Data? {
        try? Data(contentsOf: paths.dataFile)
    }

    /// `status.json`'s shape. Only the two fields the app acts on are modelled;
    /// `rungUsed`, `lastAttemptAt` and `lastSuccessAt` are the daemon's own
    /// bookkeeping.
    private struct Status: Decodable {
        let state: String
        let error: String?
    }
}
