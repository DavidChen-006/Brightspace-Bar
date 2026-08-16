// swift-tools-version: 6.2
import PackageDescription

// The dependency arrows that matter:
//
//   CourseMenu  (contract: pure values, no AppKit, no networking)
//        ↑                    ↑
//   BrightspaceBar        MenuAdapter ──→ CoursePipeline (experiment 4)
//     (the GUI)            (the wiring)
//
// BrightspaceBar depends on CourseMenu ONLY. It cannot see `Course`, cookies,
// JWTs, or URLSession — that is what lets the GUI be built and tested against
// seeded stubs while the backend stays untouched, and what stops backend detail
// from leaking into view code later.
//
// Phase 3 added MenuAdapter and, with it, the only dependency on experiment 4.
//
// Note the one unavoidable concession: `main.swift` is the composition root, so it
// must see both sides to wire them together. That is normal — the composition root
// is the single place allowed to know everything. What still must NOT happen is view
// code importing backend types, and since Swift cannot restrict imports per file,
// that rule is enforced by a test (see `ArchitectureTests`).
let package = Package(
    name: "BrightspaceBar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CourseMenu", targets: ["CourseMenu"]),
        .library(name: "MenuAdapter", targets: ["MenuAdapter"]),
        .executable(name: "BrightspaceBar", targets: ["BrightspaceBar"]),
    ],
    dependencies: [
        .package(path: "../experiment-4-course-pipeline")
    ],
    targets: [
        .target(name: "CourseMenu"),
        .testTarget(name: "CourseMenuTests", dependencies: ["CourseMenu"]),

        // The wiring. Owns the one translation the contract deliberately excludes:
        // [Course] -> MenuModel, including deriving each row's URL from its id.
        .target(
            name: "MenuAdapter",
            dependencies: [
                "CourseMenu",
                .product(name: "CoursePipeline", package: "experiment-4-course-pipeline"),
            ]
        ),
        .testTarget(
            name: "MenuAdapterTests",
            dependencies: [
                "MenuAdapter",
                "CourseMenu",
                .product(name: "CoursePipeline", package: "experiment-4-course-pipeline"),
            ]
        ),

        .executableTarget(
            name: "BrightspaceBar",
            dependencies: ["CourseMenu", "MenuAdapter"],
            exclude: ["Info.plist"],
            swiftSettings: [
                // Embeds Info.plist into the executable's __TEXT,__info_plist
                // section, the same trick RepoBar uses (Package.swift:54-57).
                // Without an Xcode project this is how a plain SPM binary can
                // carry LSUIElement and a bundle identifier.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BrightspaceBar/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "BrightspaceBarTests", dependencies: ["BrightspaceBar", "CourseMenu"]),
    ]
)
