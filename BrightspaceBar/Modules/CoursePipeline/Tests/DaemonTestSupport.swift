import Foundation
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// Support for the phase-3 daemon tests (LADDER-PLAN, "Phase 3 — the Swift swap").
//
// The Swift app no longer fetches. It spawns a Node daemon, which climbs the
// login ladder and writes `$BSB_ROOT/cache/data.json` + `status.json`; the app
// reads those files. Everything below exists so that story can be told without
// node, without a network and without a browser: a temp `BSB_ROOT`, a `/bin/sh`
// stub standing in for `node src/refresh.mjs`, and canned cache files matching
// the contract in LADDER-PLAN.
//
// Added by the phase-3 test-writer; `TestSupport.swift` is orchestrator-owned
// and untouched.
// ─────────────────────────────────────────────────────────────────────────────

/// A temp `BSB_ROOT` plus the stub daemon that writes into it.
///
/// `@unchecked Sendable` because the only shared state is a directory path —
/// every mutation goes through the file system, which the stub and the test
/// already share by design.
final class DaemonWorld: @unchecked Sendable {

    /// What `BSB_ROOT` is set to for every child this world spawns.
    let root: URL
    private let deletesOnDeinit: Bool

    init(deletesOnDeinit: Bool = true) {
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "bsb-daemon-tests-\(UUID().uuidString)")
            .standardizedFileURL
        self.deletesOnDeinit = deletesOnDeinit
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    deinit {
        if self.deletesOnDeinit {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    var paths: DaemonPaths { DaemonPaths(root: self.root) }

    /// The stub daemon script, resolved via `#filePath` like `Fixture` — no
    /// `resources:` entry, no bundle.
    static var stubExecutable: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/daemon-stubs/daemon-stub.sh")
    }

    /// A path that exists nowhere, for the spawn-failure case.
    static var missingExecutable: URL {
        URL(fileURLWithPath: "/nonexistent/bsb/daemon-\(UUID().uuidString).sh")
    }

    func runner(
        executable: URL? = nil,
        arguments: [String] = [],
        timeout: TimeInterval = 15
    ) -> DaemonRunner {
        DaemonRunner(
            executable: executable ?? Self.stubExecutable,
            arguments: arguments,
            paths: self.paths,
            timeout: timeout
        )
    }

    func courseSource(
        executable: URL? = nil,
        arguments: [String] = [],
        timeout: TimeInterval = 15
    ) -> DaemonCourseSource {
        DaemonCourseSource(runner: self.runner(executable: executable, arguments: arguments, timeout: timeout))
    }

    // MARK: - Telling the stub what to do

    enum Plan: String {
        /// Publishes the staged cache and exits 0.
        case ok
        /// Exits 0 having written nothing at all.
        case okNoData = "ok-no-data"
        /// Publishes the staged status only and exits 2 — a failed run leaves an
        /// existing `data.json` alone.
        case needsLogin = "needs-login"
        /// Writes to stderr and exits 1.
        case error
        /// Sleeps past any sane timeout, then leaves `finished.txt`.
        case hang
        /// Floods both streams past the pipe buffer, then exits 0.
        case chatty
    }

    /// `argument` is the mode's parameter: stderr text for `.error`, seconds for `.hang`.
    func plan(_ plan: Plan, argument: String = "") {
        self.write(plan: plan.rawValue, argument: argument)
    }

    /// A raw mode string, so a test can hand the stub something it does not know.
    func write(plan raw: String, argument: String = "") {
        self.write("plan.txt", "\(raw)\n\(argument)\n")
    }

    /// What the NEXT run publishes into `cache/` — the daemon's output.
    func stage(data: String? = nil, status: String? = nil) {
        if let data { self.write("next-data.json", data) }
        if let status { self.write("next-status.json", status) }
    }

    /// What is ALREADY in `cache/` when the run starts — a previous run's output.
    func seedCache(data: String? = nil, status: String? = nil) {
        try? FileManager.default.createDirectory(
            at: self.paths.cacheDirectory, withIntermediateDirectories: true
        )
        if let data { try? Data(data.utf8).write(to: self.paths.dataFile) }
        if let status { try? Data(status.utf8).write(to: self.paths.statusFile) }
    }

    // MARK: - Reading back what happened

    /// How many times a daemon was spawned against this root, ever.
    var spawnCount: Int {
        Int(self.read("spawns.txt")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// The argv the child actually received — the D8 evidence.
    var recordedArguments: [String] {
        (self.read("recorded-args.txt") ?? "")
            .split(separator: "\n")
            .map(String.init)
    }

    /// The `BSB_ROOT` the child actually saw.
    var recordedRoot: String? {
        self.read("recorded-root.txt")?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Left behind only by a `.hang` run that was allowed to finish — its absence
    /// is how a test proves the timeout really killed the child.
    var childFinished: Bool {
        FileManager.default.fileExists(atPath: self.root.appending(path: "finished.txt").path)
    }

    var cachedData: String? {
        try? String(contentsOf: self.paths.dataFile, encoding: .utf8)
    }

    // MARK: - Plumbing

    private func write(_ name: String, _ contents: String) {
        try? Data(contents.utf8).write(to: self.root.appending(path: name))
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: self.root.appending(path: name), encoding: .utf8)
    }
}

// MARK: - Canned cache files

/// The daemon's side of the contract, written out by hand.
///
/// Values are transcribed from the real captures — `myenrollments-200.json` for
/// the courses, experiment 7's deep links for the assignment ids — so a decoder
/// that quietly drifts from what the Node fetcher emits fails here rather than
/// in front of David. Never generated by the same code the app uses to read it.
enum DaemonJSON {

    /// Two genuine enrollments: one with a non-null `homeUrl` and no dates, one
    /// with null `homeUrl` and both dates present. Between them they cover every
    /// optional field in `Course`.
    static let twoCourses = """
        {
          "fetchedAt": "2026-08-15T14:00:00Z",
          "courses": [
            { "id": 412690, "name": "Purdue Civics Knowledge Test", "code": "wl.nc.civics.test",
              "role": "Learner", "isActive": true,
              "homeUrl": "https://purdue.brightspace.com/d2l/home/412690",
              "startDate": null, "endDate": null },
            { "id": 1092755, "name": "Fall 2024 CGT 11800-013 LEC", "code": "wl.202510.CGT.11800.013",
              "role": "Learner", "isActive": false, "homeUrl": null,
              "startDate": "2024-08-14T04:00:00.000Z", "endDate": "2024-12-29T04:59:00.000Z" }
          ],
          "assignments": {}
        }
        """

    /// A different list, for proving the file is re-read rather than remembered.
    static let oneCourse = """
        {
          "fetchedAt": "2026-08-15T15:00:00Z",
          "courses": [
            { "id": 440703, "name": "Scholarly Project Milestones", "code": "scholarly_project_milestones",
              "role": "Learner", "isActive": true, "homeUrl": null,
              "startDate": null, "endDate": null }
          ],
          "assignments": {}
        }
        """

    static func status(_ state: String, rungUsed: String = "none", error: String? = nil) -> String {
        let errorField = error.map { "\"\($0)\"" } ?? "null"
        return """
            { "state": "\(state)", "rungUsed": "\(rungUsed)",
              "lastAttemptAt": "2026-08-15T14:00:00Z", "lastSuccessAt": "2026-08-15T14:00:00Z",
              "error": \(errorField) }
            """
    }

    static let freshStatus = status("fresh")
}

// MARK: - Assertion helpers

extension CourseSourceError {
    var isSessionExpired: Bool { if case .sessionExpired = self { true } else { false } }
    var isMalformedBody: Bool { if case .malformedBody = self { true } else { false } }
    var isTransport: Bool { if case .transport = self { true } else { false } }

    /// The reason string a failure carries, whichever case it is — so a test can
    /// insist the daemon's own stderr reached the app.
    var reason: String {
        switch self {
        case .sessionExpired: "sessionExpired"
        case .httpStatus(let code): "httpStatus(\(code))"
        case .malformedBody(let detail): detail
        case .transport(let detail): detail
        }
    }
}

/// Runs `body` and hands back the `CourseSourceError` it threw, or nil if it did
/// not throw one. Keeps the associated-value assertions to one line each.
func courseSourceError(_ body: () async throws -> Void) async -> CourseSourceError? {
    do {
        try await body()
        return nil
    } catch let error as CourseSourceError {
        return error
    } catch {
        return nil
    }
}

/// Keeps a temp root alive exactly as long as the source that reads it, so the
/// contract suite can hand back a daemon-backed `CourseSource` from a closure.
struct RootedCourseSource: CourseSource {
    let world: DaemonWorld
    let inner: DaemonCourseSource

    func fetchCourses() async throws -> [Course] {
        try await self.inner.fetchCourses()
    }
}
