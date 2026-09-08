import Foundation
import Testing

// ═════════════════════════════════════════════════════════════════════════════
// The composition root's half of phase 3, checked by reading its source.
//
// PRIORITY: making sure the swap actually happened, and that D8 holds where it
// matters. `main.swift` is unreachable from a unit test — it is top-level code
// that ends in `app.run()` — so the only mechanism available is the one
// `ArchitectureTests` already uses on this same directory: read the file and
// make claims about its text. Crude, and better than the alternative, which is a
// green suite over an app still wired to the retired network path.
//
// The negative claim is the important one. **D8 (inverted 2026-09-08): the app
// NEVER passes `--no-full-login`.** The daemon climbs its whole ladder by
// default, full login included — that last rung is what lets a dead Entra
// wristband self-heal from a timer tick, with the MFA number on the icon. The
// app passes no argument at all; an opt-out leaking in here would leave the
// menu stale forever once the silent rung stops working. The check is on the
// quoted string literal, so prose about the flag in a comment stays legal.
//
// SCOPE: small. Reads one file from the repository; no build products, no app.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("main.swift wires the daemon, and never opts out of its full ladder")
struct DaemonWiringTests {

    /// Four parents up from `Modules/BrightspaceBar/Tests/<this file>`, so the
    /// checks work whatever directory `swift test` ran from.
    private static var compositionRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BrightspaceBar
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // <package root>
            .appending(path: "Modules/BrightspaceBar/Sources/main.swift")
            .standardizedFileURL
    }

    private func source() throws -> String {
        try String(contentsOf: Self.compositionRoot, encoding: .utf8)
    }

    @Test("the scan finds the composition root")
    func theScanIsNotVacuous() throws {
        // Arrange / Act — a check that reads an empty string would pass every
        // negative claim below while checking nothing.
        let text = try self.source()

        // Assert
        #expect(text.contains("NSApplication.shared"), "this does not look like main.swift")
    }

    @Test("the course list comes from the daemon")
    func theCourseSourceIsTheDaemon() throws {
        // Arrange / Act
        let text = try self.source()

        // Assert — nothing else in the package would notice the app still
        // running its own HTTP stack while the daemon suite went green.
        #expect(text.contains("DaemonCourseSource"))
    }

    @Test("assignments come from the same daemon cache")
    func theAssignmentSourceIsTheDaemon() throws {
        // Arrange / Act
        let text = try self.source()

        // Assert
        #expect(text.contains("DaemonAssignmentSource"))
    }

    @Test("a production timer exists at last")
    func theTimerIsWired() throws {
        // Arrange / Act — `.timer` has been a `PollTrigger` that only tests ever
        // fired. Without this line the app still refreshes at launch and on a
        // click and never again.
        let text = try self.source()

        // Assert
        #expect(text.contains("RefreshScheduler"))
    }

    @Test("the app never passes --no-full-login")
    func theAppNeverOptsOutOfTheFullLogin() throws {
        // Arrange
        let text = try self.source()

        // Act — the quoted literal only: D8 is about what gets spawned, not
        // about what the comments are allowed to mention.
        let leaks = text.contains("\"--no-full-login\"")

        // Assert
        #expect(
            !leaks,
            """
            main.swift passes --no-full-login. Every app spawn must be allowed the \
            whole ladder (D8, inverted): the full rung is the only thing that can \
            restore a session once the Entra wristband has died, and the MFA number \
            reaches the human through the icon. Opting out here leaves the menu \
            stale until someone opens a terminal.
            """
        )
    }
}
