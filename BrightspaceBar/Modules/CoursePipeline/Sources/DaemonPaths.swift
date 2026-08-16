import Foundation

/// Where the daemon's files live, decided the same way the daemon decides it.
///
/// The Node daemon writes `$BSB_ROOT/cache/data.json`; this app reads it. Two
/// programs, two languages, one layout — and nothing but agreement keeps them
/// pointed at the same directory. So this is a transcription of
/// `session-capture/src/paths.mjs`, clause by clause, and the only place in the
/// Swift side that joins a path onto the root:
///
/// ```js
/// const root = env.BSB_ROOT
///   ? path.resolve(env.BSB_ROOT)
///   : path.join(os.homedir(), "Library", "Application Support", "BrightspaceBar");
/// ```
///
/// Resolution is pure — it reports where things go and never creates them, so
/// resolving costs nothing and leaves nothing behind.
///
/// Only the data half is modelled here. `session.json` and `profile/` are the
/// daemon's alone (D7: secrets never cross into Swift), so this type cannot name
/// them.
public struct DaemonPaths: Sendable, Equatable {

    /// `BSB_ROOT` — the one dial that points the whole app at a test install.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The layout, hanging off one root.
    public var cacheDirectory: URL { self.root.appending(path: "cache") }
    public var dataFile: URL { self.cacheDirectory.appending(path: "data.json") }
    public var statusFile: URL { self.cacheDirectory.appending(path: "status.json") }

    /// Where the install lives when `BSB_ROOT` is unset — `paths.mjs`'s
    /// `DEFAULT_ROOT`, so writer and reader agree without being told.
    private static let defaultSuffix = "/Library/Application Support/BrightspaceBar"

    /// The root `environment` asks for.
    ///
    /// An **empty** `BSB_ROOT` (`BSB_ROOT= swift run …`) means *unset*, never the
    /// root directory: Node reads `""` as falsy, and a Swift side reading the
    /// variable as a plain optional would resolve it to `/` and put the cache in
    /// `/cache`, where nobody writes and no error explains why the menu is empty.
    ///
    /// A relative root is made absolute against the working directory, and
    /// traversal components are collapsed, both matching `path.resolve`.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DaemonPaths {
        guard let raw = environment["BSB_ROOT"], !raw.isEmpty else {
            return DaemonPaths(root: URL(fileURLWithPath: NSHomeDirectory() + Self.defaultSuffix))
        }
        return DaemonPaths(root: URL(fileURLWithPath: raw).standardizedFileURL)
    }
}
