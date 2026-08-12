// swift-tools-version: 6.2
import PackageDescription

// Experiment 15: THE AFTERGLOW, SPEED-GATED. Exp 14 made the sweep bodily
// (a haptic detent per crossing). This one asks whether the sweep can have a
// SKILL: cells the hover outline just left keep a fading comet tail, but only
// while you are moving fast enough. A confident flick paints a streak; a
// hesitant drag paints nothing. The gate is the point — a trail you always get
// is decoration, a trail you have to earn is an execution to get good at.
// Self-contained on purpose: exp 14 stays the haptic verdict, this folder is
// the fluency verdict, so the two never contaminate each other.
let package = Package(
    name: "Exp15",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp15",
            path: "Sources/Exp15"
        )
    ]
)
