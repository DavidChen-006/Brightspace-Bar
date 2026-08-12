// swift-tools-version: 6.2
import PackageDescription

// Experiment 14: THE STRUM. When the hover outline slides cell to cell, fire
// NSHapticFeedbackManager's .alignment tick at every boundary crossing — does
// sweeping the semester grid feel like running a thumbnail down a comb?
// Self-contained on purpose: exp 9 stays the input probe; this folder is the
// feel probe, so the two verdicts never contaminate each other.
let package = Package(
    name: "Exp14",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp14",
            path: "Sources/Exp14"
        )
    ]
)
