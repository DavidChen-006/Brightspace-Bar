// swift-tools-version: 6.2
import PackageDescription

// Experiment 13: can a macOS notification (a) fire on demand from an unsigned
// local build, (b) break through Do Not Disturb via `.timeSensitive`, and
// (c) have its on-screen lifetime pinned to exactly 6 seconds?
//
// Self-contained, like experiment 9 — the point is to find out what the OS
// actually grants an ad-hoc-signed .app, and a dependency would blur that.
let package = Package(
    name: "Exp13",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp13",
            path: "Sources/Exp13",
            exclude: ["Info.plist", "Exp13.entitlements"]
        )
    ]
)
