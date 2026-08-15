import Foundation
import Testing
import CoursePipeline

// ═════════════════════════════════════════════════════════════════════════════
// BSB_ROOT — the same resolution the daemon does, on the Swift side.
//
// PRIORITY: data integrity across a two-language boundary. The daemon writes
// `$BSB_ROOT/cache/data.json`; the app reads it. If the two disagree about where
// the root is — by one env-var edge case — the app reads a file nobody writes and
// the menu is permanently empty, with no error anywhere to explain it. So this
// suite is a transcription check against `session-capture/src/paths.mjs`, clause
// by clause, not a test of "does it join a path".
//
//   const root = env.BSB_ROOT
//     ? path.resolve(env.BSB_ROOT)
//     : path.join(os.homedir(), "Library", "Application Support", "BrightspaceBar");
//
// The truthiness test is the sharp edge: `BSB_ROOT=` (empty) means *unset* in
// Node, not the root directory. A Swift side reading `environment["BSB_ROOT"]`
// as a plain optional would resolve "" to "/" and put the cache in `/cache`.
//
// SCOPE: small. Pure resolution over an injected environment — no file system,
// which is why `resolve(environment:)` takes the environment as a parameter.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("BSB_ROOT resolution mirrors paths.mjs exactly")
struct DaemonPathsTests {

    /// The layout the daemon writes into, from the plan's BSB_ROOT table.
    private static let expectedDefaultSuffix = "Library/Application Support/BrightspaceBar"

    @Test("BSB_ROOT points every path at that root")
    func anExplicitRootIsUsedVerbatim() {
        // Arrange
        let root = NSTemporaryDirectory() + "bsb-explicit-root"

        // Act
        let paths = DaemonPaths.resolve(environment: ["BSB_ROOT": root])

        // Assert — the four locations the app and the daemon must agree on.
        #expect(paths.root.standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path)
        #expect(paths.cacheDirectory.lastPathComponent == "cache")
        #expect(paths.dataFile.path.hasSuffix("/cache/data.json"))
        #expect(paths.statusFile.path.hasSuffix("/cache/status.json"))
    }

    @Test("an empty BSB_ROOT means unset, never the root directory")
    func anEmptyRootFallsBackToTheDefault() {
        // Arrange — `BSB_ROOT= swift run …`, which Node reads as falsy.
        let empty = DaemonPaths.resolve(environment: ["BSB_ROOT": ""])

        // Act
        let path = empty.root.path

        // Assert — the failure this defends against is `/cache/data.json`.
        #expect(path != "/")
        #expect(
            path.hasSuffix(Self.expectedDefaultSuffix),
            "an empty BSB_ROOT resolved to \(path); paths.mjs treats it as unset"
        )
    }

    @Test("an absent BSB_ROOT falls back to Application Support")
    func theDefaultRootIsTheInstallLocation() {
        // Arrange / Act
        let paths = DaemonPaths.resolve(environment: [:])

        // Assert — same directory `Scripts/refresh-session.sh` and the daemon use.
        #expect(paths.root.path.hasSuffix(Self.expectedDefaultSuffix))
        #expect(paths.root.path.hasPrefix(NSHomeDirectory()))
        #expect(paths.dataFile.path.hasSuffix("\(Self.expectedDefaultSuffix)/cache/data.json"))
    }

    @Test("a relative BSB_ROOT resolves against the working directory")
    func aRelativeRootBecomesAbsolute() {
        // Arrange — `path.resolve` makes relative roots absolute; a Swift side
        // that kept the relative path would spawn the daemon with one meaning of
        // "cache" and read another.
        let expected = FileManager.default.currentDirectoryPath + "/relative-root"

        // Act
        let paths = DaemonPaths.resolve(environment: ["BSB_ROOT": "relative-root"])

        // Assert
        #expect(paths.root.path == expected)
    }

    @Test("a BSB_ROOT with traversal components is normalized")
    func traversalIsResolved() {
        // Arrange / Act — `path.resolve("/tmp/a/../b")` is "/tmp/b".
        let paths = DaemonPaths.resolve(environment: ["BSB_ROOT": "/tmp/a/../b"])

        // Assert
        #expect(paths.root.path == "/tmp/b")
    }

    @Test("a root constructed directly lays out the same four paths")
    func theLayoutHangsOffOneRoot() {
        // Arrange
        let root = URL(fileURLWithPath: "/tmp/bsb-layout")

        // Act
        let paths = DaemonPaths(root: root)

        // Assert
        #expect(paths.cacheDirectory.path == "/tmp/bsb-layout/cache")
        #expect(paths.dataFile.path == "/tmp/bsb-layout/cache/data.json")
        #expect(paths.statusFile.path == "/tmp/bsb-layout/cache/status.json")
    }
}
