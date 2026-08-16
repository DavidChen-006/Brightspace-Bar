// swift-tools-version: 6.2
import PackageDescription

// Experiment 17: how does the menu-bar app learn that the daemon wrote
// cache/mfa.json? Exp 12 proved the icon FLIP costs 1-4 ms; that leaves the
// transport — the gap between another process renaming a 60-byte file into
// place and this process having repainted. Three candidates (kqueue directory
// source, FSEvents, a 500 ms poll) measured end to end against a writer that
// uses the daemon's exact atomic temp+rename.
// Self-contained on purpose: this measures pickup, not BrightspaceBar.
let package = Package(
    name: "Exp17",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp17",
            path: "Sources/Exp17"
        )
    ]
)
