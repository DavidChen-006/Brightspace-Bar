// swift-tools-version: 6.2
import PackageDescription

// Experiment 12: can the status item ITSELF carry the MFA number-matching code?
// The login flow can scrape the 2-digit code headlessly; the open question is
// how to show it with zero interaction — no click, no mouse, immune to Do Not
// Disturb. A notification fails all three. The menu bar icon does not.
// Self-contained on purpose: this measures the flip, not BrightspaceBar.
let package = Package(
    name: "Exp12",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp12",
            path: "Sources/Exp12"
        )
    ]
)
