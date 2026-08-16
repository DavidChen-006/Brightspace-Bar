import Testing
@testable import BrightspaceBar

// The switch that plugs one of two openers into the click seam. What matters and
// can silently break: the control variable resolves to the right target, an
// unknown value degrades to the shipped default rather than disabling clicks,
// and each target builds the opener it names.
@Suite("BrowserTarget — the browser switch")
struct BrowserTargetTests {

    @Test("ships defaulting to Chromium")
    func defaultIsChromium() {
        #expect(BrowserTarget.productionDefault == .chromium)
    }

    @Test("an unset control variable resolves to the shipped default")
    func unsetResolvesToDefault() {
        #expect(BrowserTarget.resolve([:]) == .chromium)
    }

    @Test("BSB_BROWSER_TARGET=system selects the default browser")
    func systemIsSelectable() {
        #expect(BrowserTarget.resolve(["BSB_BROWSER_TARGET": "system"]) == .system)
    }

    @Test("BSB_BROWSER_TARGET=chromium selects the signed-in profile")
    func chromiumIsSelectable() {
        #expect(BrowserTarget.resolve(["BSB_BROWSER_TARGET": "chromium"]) == .chromium)
    }

    @Test("an unrecognized value degrades to the default, never to no-click")
    func unknownDegradesToDefault() {
        #expect(BrowserTarget.resolve(["BSB_BROWSER_TARGET": "safari"]) == .chromium)
    }

    @Test(".system builds the workspace opener")
    func systemBuildsWorkspaceOpener() {
        #expect(BrowserTarget.system.makeOpener() is WorkspaceURLOpener)
    }

    @Test(".chromium builds the Chromium opener")
    func chromiumBuildsChromiumOpener() {
        #expect(BrowserTarget.chromium.makeOpener() is ChromiumURLOpener)
    }
}
