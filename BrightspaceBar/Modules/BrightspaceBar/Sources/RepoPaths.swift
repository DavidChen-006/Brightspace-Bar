import Foundation

/// Where the sibling `session-capture` package lives when nobody said otherwise.
///
/// The env overrides (`BSB_OPEN_CLI`, `BSB_REFRESH_CLI`) stay first priority —
/// they are how a packaged or relocated install points elsewhere. This helper
/// only supplies the fallback beneath them: `#filePath` pins the checkout the
/// binary was *built* from, which is exactly right for the run-from-source
/// workflow (`make run` in a cloned repo, wherever on disk it landed) and
/// wrong for a binary that was copied off the build machine — which is what
/// the env vars are for. The original hard-wired
/// `~/Developer/BrightspaceBar/...` stays as the last resort, in case the
/// build-time checkout has since been deleted.
enum RepoPaths {
    /// The repo root derived from this source file's compile-time path: the
    /// file lives at `<repo>/BrightspaceBar/Modules/BrightspaceBar/Sources/`,
    /// so the root is four directories up.
    static var repoRoot: String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.path
    }

    /// The default path to a `session-capture` CLI entry point, e.g.
    /// `sessionCaptureCLI("browser-open.mjs")`. Prefers the build-time
    /// checkout when it still exists, then the historic home-directory layout.
    static func sessionCaptureCLI(_ script: String) -> String {
        let derived = repoRoot + "/session-capture/src/" + script
        if FileManager.default.fileExists(atPath: derived) {
            return derived
        }
        return NSHomeDirectory() + "/Developer/BrightspaceBar/session-capture/src/" + script
    }
}
