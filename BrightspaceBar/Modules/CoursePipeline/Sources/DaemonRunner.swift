import Foundation

/// How a daemon run ended, in the app's vocabulary.
///
/// The daemon's exit codes are the whole contract (LADDER-PLAN, "File
/// contracts"): `0` a fresh cache was written · `2` the ladder ran out and a
/// human is needed · `1` something unexpected. Anything else the app can observe
/// — it never started, it never finished — is its own case, because a failure
/// that reads as success would replace David's menu with an empty one.
public enum DaemonOutcome: Equatable, Sendable {
    /// Exit 0. A fresh `cache/data.json` should now be on disk.
    case ranOk
    /// Exit 2. The ladder was exhausted; the previous cache is untouched.
    case needsLogin
    /// Any other exit code, carrying the daemon's own last words.
    case failed(String)
    /// The child outran its timeout and was killed.
    case timedOut
    /// The child never started — no node, or a moved checkout.
    case spawnFailed(String)
}

/// Spawns the daemon once and reports how it went.
///
/// This is the only place the app leaves its own process, and the two traps here
/// are both learned rather than imagined (RepoBar's `GitProcessRunner`):
///
///   - **No `Pipe`.** A pipe plus a wait deadlocks the moment the child fills the
///     ~64KB buffer, and a Node CLI logging its climb will. `stderr` goes to a
///     temp file; `stdout` goes to `/dev/null`, since the daemon reports through
///     `stderr` by contract (`refresh.mjs` logs with `console.error`).
///   - **The timeout must kill.** Not merely stop waiting: an abandoned child
///     would outlive the refresh that started it. SIGTERM, one second of grace,
///     then SIGKILL.
///
/// `stdin` is `/dev/null`, so a child that ever tries to ask a question gets EOF
/// instead of hanging a menu-bar app forever.
///
/// **D8: this type never invents an argument.** The child receives exactly
/// `arguments`, so `--allow-full-login` can only ever appear if a caller passed
/// it — and no app call site does. Every spawn the app makes is cron-safe.
public struct DaemonRunner: Sendable {

    private let executable: URL
    private let arguments: [String]
    /// The root handed to the child as `BSB_ROOT`, and the same root the sources
    /// read the resulting cache from. One value, so the two cannot disagree.
    public let paths: DaemonPaths
    private let timeout: TimeInterval

    public init(executable: URL, arguments: [String], paths: DaemonPaths, timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.paths = paths
        self.timeout = timeout
    }

    /// Runs the daemon to completion (or to its timeout) and classifies the exit.
    ///
    /// Never throws: every way this can go wrong is one of the outcomes, and a
    /// caller that had to catch as well as switch would have two taxonomies to
    /// keep aligned.
    public func run() async -> DaemonOutcome {
        await withCheckedContinuation { continuation in
            // A dedicated queue, not the cooperative pool: the work below blocks
            // on a semaphore for as long as the daemon takes.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.spawn())
            }
        }
    }

    // MARK: - Doing: one child process, start to finish

    private func spawn() -> DaemonOutcome {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "bsb-daemon-\(UUID().uuidString)")
        guard let errorFile = try? Self.makeErrorFile(in: scratch) else {
            return .spawnFailed("could not open a file for the daemon's output")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        defer { try? errorFile.handle.close() }

        let process = Process()
        process.executableURL = self.executable
        process.arguments = self.arguments
        process.environment = self.childEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorFile.handle

        let didExit = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in didExit.signal() }

        do {
            try process.run()
        } catch {
            return .spawnFailed(String(describing: error))
        }

        if didExit.wait(timeout: .now() + self.timeout) == .timedOut {
            process.terminate()
            if didExit.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = didExit.wait(timeout: .now() + 1)
            }
            return .timedOut
        }

        try? errorFile.handle.close()
        return Self.classify(
            status: process.terminationStatus,
            stderr: Self.tail(of: errorFile.url)
        )
    }

    /// The parent's environment plus the one variable that matters. `BSB_ROOT` is
    /// how the child learns which install to write, and it is passed explicitly
    /// rather than inherited so a test root always wins over an ambient one.
    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["BSB_ROOT"] = self.paths.root.path
        return environment
    }

    private static func makeErrorFile(in directory: URL) throws -> (url: URL, handle: FileHandle) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "stderr")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    /// The last of what the daemon said. Bounded: a chatty run must not turn its
    /// whole log into an error message.
    private static func tail(of url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(1_000))
    }

    // MARK: - Deciding: pure classification of an exit

    /// Nothing but 0 may read as success, and nothing but 2 as needs-login.
    static func classify(status: Int32, stderr: String) -> DaemonOutcome {
        switch status {
        case 0: .ranOk
        case 2: .needsLogin
        default: .failed(
            stderr.isEmpty ? "the daemon exited \(status)" : "the daemon exited \(status): \(stderr)"
        )
        }
    }
}
