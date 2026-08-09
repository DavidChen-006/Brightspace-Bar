import AppKit
@testable import RepoBar
import Testing

@Suite("SettingsWindowSizing")
struct SettingsWindowSizingTests {
    @Test
    func `returns desired size when no visible frame is available`() {
        let desired = NSSize(width: 600, height: 800)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: desired,
            visibleFrame: nil,
            chrome: NSSize(width: 0, height: 28)
        )
        #expect(result == desired)
    }

    @Test
    func `clamps content width when chrome plus content overflows the screen`() {
        // A 13" MacBook-ish visible frame (~1440 wide minus sidebars). Window chrome is 16
        // px wide; desired content (1000) + chrome (16) > visible width (1440) is fine, but
        // we still want a tight clamp on the next test.
        let visible = NSRect(x: 0, y: 0, width: 1016, height: 800)
        let chrome = NSSize(width: 16, height: 28)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: 1000, height: 600),
            visibleFrame: visible,
            chrome: chrome
        )
        // 1000 + 16 == 1016 fits exactly; no clamping expected.
        #expect(result.width == 1000)
        #expect(result.height == 600)
    }

    @Test
    func `clamps content height so the window doesn't slide under the Dock`() {
        // Simulate a small visible area with a chunky Dock at the bottom (height == 600).
        let visible = NSRect(x: 0, y: 50, width: 1440, height: 600)
        let chrome = NSSize(width: 0, height: 28)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: 540, height: 770),
            visibleFrame: visible,
            chrome: chrome
        )
        // 770 > 600 - 28 → content must shrink so the window fits in the visible area.
        #expect(result.height == 572)
        #expect(result.width == 540)
    }

    @Test
    func `clamps content height using the full settings toolbar chrome`() {
        let visible = NSRect(x: 0, y: 50, width: 1440, height: 600)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: 540, height: 660),
            visibleFrame: visible,
            chrome: NSSize(width: 0, height: 88)
        )
        #expect(result.height == 512)
        #expect(result.height + 88 == visible.height)
    }

    @Test
    func `clamps both axes when the desired window is larger than the screen`() {
        let visible = NSRect(x: 0, y: 0, width: 400, height: 300)
        let chrome = NSSize(width: 8, height: 24)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: 980, height: 770),
            visibleFrame: visible,
            chrome: chrome
        )
        #expect(result.width == 392)
        #expect(result.height == 276)
    }

    @Test
    func `never returns a non-positive size even when the visible frame is degenerate`() {
        let visible = NSRect(x: 0, y: 0, width: 4, height: 4)
        let chrome = NSSize(width: 16, height: 28)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: 980, height: 770),
            visibleFrame: visible,
            chrome: chrome
        )
        #expect(result.width >= 1)
        #expect(result.height >= 1)
    }

    @Test
    func `treats negative chrome as zero so external callers can't break the math`() {
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let result = SettingsWindowSizing.clampedContentSize(
            desired: NSSize(width: 540, height: 600),
            visibleFrame: visible,
            chrome: NSSize(width: -5, height: -10)
        )
        #expect(result.width == 540)
        #expect(result.height == 600)
    }

    @Test
    func `minimumContentSize preserves the declared content coordinate floor`() {
        let minimum = NSSize(width: 420, height: 360)
        let result = SettingsWindowSizing.minimumContentSize(for: minimum)
        #expect(result == minimum)
    }

    @Test
    func `minimumContentSize never goes below 1`() {
        let result = SettingsWindowSizing.minimumContentSize(
            for: NSSize(width: -20, height: 0)
        )
        #expect(result.width == 1)
        #expect(result.height == 1)
    }

    @Test
    func `minimumContentSize does not exceed a smaller screen maximum`() {
        let result = SettingsWindowSizing.minimumContentSize(
            for: NSSize(width: 420, height: 360),
            maximum: NSSize(width: 392, height: 276)
        )
        #expect(result.width == 392)
        #expect(result.height == 276)
    }

    @Test
    func `maximumContentSize subtracts chrome from the visible frame`() {
        let result = SettingsWindowSizing.maximumContentSize(
            for: NSRect(x: 0, y: 63, width: 1440, height: 807),
            chrome: NSSize(width: 16, height: 28)
        )
        #expect(result.width == 1424)
        #expect(result.height == 779)
    }

    @Test
    func `maximumContentSize never goes below 1 when chrome exceeds the visible frame`() {
        let result = SettingsWindowSizing.maximumContentSize(
            for: NSRect(x: 0, y: 0, width: 20, height: 20),
            chrome: NSSize(width: 100, height: 100)
        )
        #expect(result.width == 1)
        #expect(result.height == 1)
    }

    @Test
    func `window origin clamps to the visible right edge after widening`() {
        let visible = NSRect(x: 100, y: 63, width: 1440, height: 807)
        let result = SettingsWindowSizing.clampedWindowOriginX(
            proposedOriginX: 1200,
            windowWidth: 980,
            visibleFrame: visible
        )
        #expect(result == 560)
    }

    @Test
    func `window origin clamps to the visible left edge`() {
        let visible = NSRect(x: 100, y: 63, width: 1440, height: 807)
        let result = SettingsWindowSizing.clampedWindowOriginX(
            proposedOriginX: 20,
            windowWidth: 540,
            visibleFrame: visible
        )
        #expect(result == 100)
    }

    @Test
    func `window origin remains unchanged when the resized frame is already visible`() {
        let visible = NSRect(x: 0, y: 63, width: 1440, height: 807)
        let result = SettingsWindowSizing.clampedWindowOriginY(
            proposedOriginY: 120,
            windowHeight: 648,
            visibleFrame: visible
        )
        #expect(result == 120)
    }

    @Test
    func `window origin clamps to the visible bottom edge`() {
        let visible = NSRect(x: 0, y: 63, width: 1440, height: 807)
        let result = SettingsWindowSizing.clampedWindowOriginY(
            proposedOriginY: 40,
            windowHeight: 648,
            visibleFrame: visible
        )
        #expect(result == visible.minY)
    }

    @Test
    func `window origin clamps to the visible top edge`() {
        let visible = NSRect(x: 0, y: 63, width: 1440, height: 807)
        let result = SettingsWindowSizing.clampedWindowOriginY(
            proposedOriginY: 400,
            windowHeight: 648,
            visibleFrame: visible
        )
        #expect(result == visible.maxY - 648)
    }
}
