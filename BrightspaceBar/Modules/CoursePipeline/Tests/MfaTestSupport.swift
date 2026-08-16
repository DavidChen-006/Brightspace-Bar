import Foundation
import CoursePipeline

// ─────────────────────────────────────────────────────────────────────────────
// Support for BUILD 2 phase B — the MFA number on the status-bar icon.
//
// The daemon writes `$BSB_ROOT/cache/mfa.json` mid-login and deletes it on every
// exit path; the app watches the directory and renders the number. Everything
// below exists so that story can be told without node, without a browser and
// without a login: a temp `BSB_ROOT`, and a writer that reproduces the daemon's
// atomic write byte for byte — temp file in the SAME directory, then `rename(2)`
// (`session-capture/src/orchestrate.mjs`'s `writeJsonAtomic`).
//
// The write technique is not an incidental detail. A rename is two directory
// events and the first one is a lie (exp 17, trap 2), and a rename is also what
// makes a watch on the FILE go deaf after one write (trap 1). A helper that used
// `Data.write(to:)` instead would quietly stop testing either of those.
//
// Added by the phase-B test-writer. `TestSupport.swift` is orchestrator-owned and
// `DaemonTestSupport.swift` belongs to phase 3; both are untouched.
// ─────────────────────────────────────────────────────────────────────────────

/// A temp `BSB_ROOT` with a `cache/` directory, and the daemon's write behaviour.
@MainActor
final class MfaWorld {

    let root: URL

    /// `createsCacheDirectory: false` reproduces a fresh install — the app is up
    /// before the daemon has ever run, so `cache/` does not exist yet.
    init(createsCacheDirectory: Bool = true) {
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "bsb-mfa-tests-\(UUID().uuidString)")
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        if createsCacheDirectory {
            self.createCacheDirectory()
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: self.root)
    }

    var paths: DaemonPaths { DaemonPaths(root: self.root) }
    var cacheDirectory: URL { self.paths.cacheDirectory }
    var mfaFile: URL { self.cacheDirectory.appending(path: "mfa.json") }

    var mfaFileExists: Bool { FileManager.default.fileExists(atPath: self.mfaFile.path) }

    func createCacheDirectory() {
        try? FileManager.default.createDirectory(
            at: self.cacheDirectory, withIntermediateDirectories: true
        )
    }

    /// `reset.sh --cache` — the whole directory, not just its contents.
    func deleteCacheDirectory() {
        try? FileManager.default.removeItem(at: self.cacheDirectory)
    }

    // MARK: - Writing the challenge the way the daemon writes it

    /// One atomic publish of `mfa.json`, `writeJsonAtomic` transcribed:
    /// a dot-prefixed temp file beside the target, then `rename(2)` over it.
    func writeChallenge(number: String, mintedAt: Date) {
        self.writeChallenge(json: MfaFixture.json(number: number, mintedAt: mintedAt))
    }

    /// The same publish, with the file's bytes given verbatim.
    func writeChallenge(json: String) {
        let temp = self.cacheDirectory.appending(path: ".mfa.json.\(getpid()).tmp")
        try? Data(json.utf8).write(to: temp)
        _ = rename(temp.path, self.mfaFile.path)
    }

    /// The daemon's exit path: the challenge is over, the file goes away.
    func deleteChallenge() {
        try? FileManager.default.removeItem(at: self.mfaFile)
    }
}

// MARK: - The file's bytes

/// `cache/mfa.json` as LADDER-PLAN specifies it, written out by hand.
///
/// `mintedAt` carries milliseconds because that is what the writer emits —
/// Node's `new Date().toISOString()` always does — and a Swift reader using
/// `JSONDecoder`'s stock `.iso8601` strategy rejects exactly that string. The
/// epoch below was computed by `date -u`, never by the code under test.
enum MfaFixture {

    /// `2026-08-15T14:00:00Z`, per `date -u -j -f %Y-%m-%dT%H:%M:%SZ … +%s`.
    static let mintedAt = Date(timeIntervalSince1970: 1_786_802_400)
    static let mintedAtLiteral = "2026-08-15T14:00:00.000Z"

    /// The whole file, as the daemon lays it out (`JSON.stringify(value, null, 2)`
    /// plus a trailing newline). `number` is escaped the way a JSON encoder would
    /// escape it, so a case like "a digit, a newline, a digit" reaches the reader
    /// as a well-formed file with a badly-formed number — which is the thing that
    /// case is about.
    static func json(number: String, mintedAt: Date) -> String {
        self.json(number: self.quoted(number), mintedAtLiteral: self.iso(mintedAt))
    }

    static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Both fields as raw JSON text, for the malformed cases.
    static func json(number: String, mintedAtLiteral: String) -> String {
        """
        {
          "number": \(number),
          "mintedAt": "\(mintedAtLiteral)"
        }

        """
    }

    /// A fresh challenge relative to the fixed epoch above.
    static var fresh: String { MfaFixture.json(number: "20", mintedAt: MfaFixture.mintedAt) }

    /// ISO-8601 with milliseconds and a `Z`, which is the only shape the writer
    /// produces. Built with a formatter configured explicitly rather than with
    /// `ISO8601DateFormatter()`'s defaults, so this stays a statement about the
    /// wire format instead of a Foundation default the reader might share.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func data(_ json: String) -> Data { Data(json.utf8) }
}
