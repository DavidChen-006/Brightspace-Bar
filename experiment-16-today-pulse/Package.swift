// swift-tools-version: 6.2
import PackageDescription

// Experiment 16: THE TODAY PULSE. The grid's rule is calm-until-touched, and
// this is its one licensed exception: the today cell breathes on a slow sine
// so "you are here" is findable at a glance without ever reading as an alarm.
// Its own folder for the same reason exp 14 got one — the pulse verdict must
// not be contaminated by the strum verdict, even though this row carries both.
let package = Package(
    name: "Exp16",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Exp16",
            path: "Sources/Exp16"
        )
    ]
)
