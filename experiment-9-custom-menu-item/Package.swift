// swift-tools-version: 6.2
import PackageDescription

// Experiment 9: can a custom-rendered NSMenuItem give hover unity (title +
// graph highlighting as one component)? Deliberately self-contained — no
// dependency on BrightspaceBar or RepoBar; the point is to discover what a
// port COSTS, and a dependency would hide it.
let package = Package(
    name: "Exp9",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp9",
            path: "Sources/Exp9",
            exclude: ["Info.plist"]
        )
    ]
)
