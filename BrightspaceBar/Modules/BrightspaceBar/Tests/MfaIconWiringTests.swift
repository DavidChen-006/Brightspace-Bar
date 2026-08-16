import AppKit
import Foundation
import Testing

import BrightspaceBar

// ═════════════════════════════════════════════════════════════════════════════
// The GUI end of BUILD 2: the number actually reaching the menu bar.
//
// `StatusBarController` owns the `NSStatusItem` and is deliberately not
// instantiated by unit tests — a status item needs a real UI session, which is
// why that layer has always been covered by the launch smoke test. So this file
// makes two kinds of claim:
//
//   1. About the one piece that IS testable headless: the attributed string the
//      icon paints. Exp 12 measured the flip at 1–4 ms and found the one
//      outlier — the FIRST attributed title costs 19 ms, all of it font
//      resolution — and found that monospaced digits are what stop the item
//      resizing between codes like 11 and 88, which shoves every status item to
//      its left. Both of those are behaviour, and behaviour can be tested.
//
//   2. About the wiring, by reading the source, exactly as `DaemonWiringTests`
//      and `ArchitectureTests` do. `main.swift` is top-level code ending in
//      `app.run()`; there is no other mechanism.
//
// PRIORITY: that the seam exists in the one shape the architecture allows.
// `show(code: String?)` takes a STRING, not an `IconState`: `IconState` lives in
// CoursePipeline, and `ArchitectureTests` forbids any view file from importing a
// backend module. The composition root is the one place allowed to know both
// words for this, so it is the composition root that unwraps the state.
//
// SCOPE: small. One attributed string, and two files read off disk.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("The MFA badge as the menu bar draws it")
@MainActor
struct MfaBadgeTitleTests {

    @Test("the number is what the icon says")
    func theTitleCarriesTheCode() {
        // Arrange / Act
        let title = StatusBarController.badgeTitle("20")

        // Assert — whatever decoration surrounds it, the digits David types into
        // his phone have to be in there.
        #expect(title.string.contains("20"))
    }

    @Test("the badge is not blank")
    func theTitleIsNotEmpty() {
        // Arrange / Act — a badge that renders to nothing is an icon that
        // silently disappears from the menu bar mid-login.
        let title = StatusBarController.badgeTitle("7")

        // Assert
        #expect(title.length > 0)
        #expect(title.string.contains("7"))
    }

    @Test("two codes of the same length are the same width")
    func digitsAreMonospaced() {
        // Arrange — exp 12: `.variableLength` means the item resizes with its
        // title and every status item to its LEFT slides over. One nudge when
        // the challenge appears is fine; the item twitching as the number
        // changes is not, and proportional digits make 11 narrower than 88.
        let narrow = StatusBarController.badgeTitle("11")
        let wide = StatusBarController.badgeTitle("88")

        // Act
        let difference = abs(narrow.size().width - wide.size().width)

        // Assert
        #expect(difference < 0.01, "11 and 88 render \(difference)pt apart — the digits are not monospaced")
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// The wiring, checked by reading the source.
// ═════════════════════════════════════════════════════════════════════════════

@Suite("The MFA number is wired from the watcher to the icon")
struct MfaIconWiringTests {

    /// Four parents up from `Modules/BrightspaceBar/Tests/<this file>`, so the
    /// checks work whatever directory `swift test` ran from.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BrightspaceBar
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // <package root>
            .standardizedFileURL
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appending(path: path), encoding: .utf8)
    }

    private func controllerSource() throws -> String {
        try self.source("Modules/BrightspaceBar/Sources/StatusBarController.swift")
    }

    private func compositionRoot() throws -> String {
        try self.source("Modules/BrightspaceBar/Sources/main.swift")
    }

    @Test("the scan finds both files")
    func theScanIsNotVacuous() throws {
        // Arrange / Act — a read that returned an empty string would pass every
        // claim below while checking nothing.
        let controller = try self.controllerSource()
        let main = try self.compositionRoot()

        // Assert
        #expect(controller.contains("class StatusBarController"))
        #expect(main.contains("NSApplication.shared"), "this does not look like main.swift")
    }

    // MARK: - The seam

    @Test("the controller takes a code, or nil for the logo")
    func theControllerHasTheSeam() throws {
        // Arrange / Act — a String and not an IconState: view files may not
        // import CoursePipeline (ArchitectureTests), and nil is how the caller
        // says "the challenge is over, put the book back".
        let text = try self.controllerSource()

        // Assert
        #expect(
            text.contains("public func show(code: String?)"),
            "StatusBarController must expose `public func show(code: String?)`"
        )
    }

    @Test("the number is painted as an attributed title")
    func theFlipUsesTheMeasuredPath() throws {
        // Arrange / Act — exp 12 measured this exact path at 1–4 ms on the
        // existing button, with no status item torn down and rebuilt, which is
        // what keeps the item in its slot across the flip.
        let text = try self.controllerSource()

        // Assert
        #expect(text.contains("attributedTitle"))
    }

    @Test("the font is warmed at startup")
    func theFirstNumberIsNotTheSlowOne() throws {
        // Arrange / Act — exp 12: the FIRST attributed title costs 19 ms of font
        // resolution and every later one is under a millisecond. Unwarmed, that
        // 19 ms lands on the one paint that matters — the number appearing while
        // David waits — and makes a 2.6 ms transport look slow. One throwaway
        // render at startup pays it while nobody is watching.
        let text = try self.controllerSource()

        // Assert
        #expect(
            text.contains("warmUp"),
            """
            StatusBarController must warm the font at startup: call a `warmUp` \
            step from `init` that renders one throwaway badge title through \
            `badgeTitle`, so the 19 ms first-attributed-title cost is paid before \
            a challenge ever arrives.
            """
        )
        #expect(
            text.contains("badgeTitle"),
            "the warm-up must render through badgeTitle — warming a different font warms nothing"
        )
    }

    // MARK: - The composition root

    @Test("the composition root builds the watcher")
    func theWatcherIsWired() throws {
        // Arrange / Act — the watcher lives in CoursePipeline and the controller
        // may not see it; main.swift is the only file allowed to know both.
        let text = try self.compositionRoot()

        // Assert
        #expect(text.contains("MfaWatcher"))
    }

    @Test("the watcher outlives the line that made it")
    func theWatcherIsHeldForTheLifeOfTheProcess() throws {
        // Arrange — a watcher assigned to a local inside a branch is deallocated
        // at the end of that branch, cancelling its kqueue source. The app would
        // launch, wire everything, and never see a single challenge. The existing
        // `let refreshTimer = RefreshScheduler()` is held at top level for the
        // same reason.
        let text = try self.compositionRoot()

        // Act
        let heldAtTopLevel = text.range(
            of: #"(?m)^let\s+\w+\s*=\s*MfaWatcher\("#,
            options: .regularExpression
        ) != nil

        // Assert
        #expect(heldAtTopLevel, "MfaWatcher must be bound by a top-level `let` in main.swift")
    }

    @Test("what the watcher reports reaches the icon")
    func theWatcherIsConnectedToTheController() throws {
        // Arrange / Act — a watcher nobody listens to is 2.6 ms of nothing.
        let text = try self.compositionRoot()

        // Assert
        #expect(
            text.contains("show(code:"),
            "main.swift must hand the watcher's reports to StatusBarController.show(code:)"
        )
    }
}
