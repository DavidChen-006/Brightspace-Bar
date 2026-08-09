import AppKit
@testable import RepoBar
import Testing

@MainActor
struct ColorContrastTests {
    @Test
    func `ensures contrast meets minimum`() {
        let background = NSColor(srgbRed: 0.0, green: 0.47, blue: 1.0, alpha: 1.0)
        let foreground = NSColor(srgbRed: 0.12, green: 0.55, blue: 0.24, alpha: 1.0)

        let appearance = NSAppearance(named: .aqua)
        let adjusted = foreground.ensuringContrast(on: background, minRatio: 3.0, appearance: appearance)
        let ratio = adjusted.contrastRatio(with: background, appearance: appearance)

        #expect(ratio >= 3.0)
    }
}
