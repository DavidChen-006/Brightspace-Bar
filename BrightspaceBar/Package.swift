// swift-tools-version: 6.2
import PackageDescription

// One package, six modules, each self-contained under Modules/<Name>/ with its
// own Sources/, Tests/, and Makefile. The dependency arrows that matter:
//
//   CoursePipeline  ←──  AssignmentPipeline  (backend: per-course work items)
//        ↑                            ↑
//        └──────────────────  QuizPipeline   (quiz parsing + the quiz deep link)
//        ↑
//   MenuAdapter ──→ CourseMenu   (the contract: pure values, no AppKit, no network)
//                       ↑
//                  BrightspaceBar (the GUI)
//
// There is no session module any more: credentials live entirely on the Node
// daemon's side of the boundary (LADDER-PLAN D7), and the backend's only source
// of data is the cache the daemon writes.
//
// BrightspaceBar depends on CourseMenu ONLY — it cannot see `Course`, cookies,
// JWTs, or URLSession. That is what lets the GUI be built and tested against
// seeded stubs, and stops backend detail from leaking into view code.
//
// The one concession: `main.swift` is the composition root, so it must see both
// sides to wire them together. Swift cannot restrict imports per file, so that
// rule is enforced by a test (`ArchitectureTests`).
let package = Package(
    name: "BrightspaceBar",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoursePipeline", targets: ["CoursePipeline"]),
        .library(name: "AssignmentPipeline", targets: ["AssignmentPipeline"]),
        .library(name: "QuizPipeline", targets: ["QuizPipeline"]),
        .library(name: "CourseMenu", targets: ["CourseMenu"]),
        .library(name: "MenuAdapter", targets: ["MenuAdapter"]),
        .library(name: "ManualItems", targets: ["ManualItems"]),
        .executable(name: "BrightspaceBar", targets: ["BrightspaceBar"]),
    ],
    targets: [
        // ── The backend: parse, cache, poll, spawn ───────────────────────────
        .target(
            name: "CoursePipeline",
            path: "Modules/CoursePipeline/Sources"
        ),
        .testTarget(
            name: "CoursePipelineTests",
            dependencies: ["CoursePipeline"],
            path: "Modules/CoursePipeline/Tests",
            // Fixtures are read via #filePath (see TestSupport.Fixture), not as
            // bundle resources — excluded so SPM does not complain about them.
            exclude: ["Fixtures"]
        ),

        // ── The backend: one course's assignments, fanned out ────────────────
        //
        // Depends on CoursePipeline for the shared vocabulary — `Course`, `Clock`,
        // `CacheOutcome`, `CourseSourceError`. Two backend modules with two words
        // for "the fetch failed, keep what you had" would be two places to sync.
        .target(
            name: "AssignmentPipeline",
            dependencies: ["CoursePipeline"],
            path: "Modules/AssignmentPipeline/Sources"
        ),
        .testTarget(
            name: "AssignmentPipelineTests",
            dependencies: ["AssignmentPipeline", "CoursePipeline"],
            path: "Modules/AssignmentPipeline/Tests",
            // Fixtures are read via #filePath (see TestSupport.Fixture), not as
            // bundle resources. Excluding the whole directory also covers the
            // README documenting them, which SPM would otherwise reject as an
            // unhandled resource.
            exclude: ["Fixtures"]
        ),

        // ── The backend: the same items, from the quizzes route ───────────────
        //
        // Depends on AssignmentPipeline rather than paralleling it: `QuizParser`
        // produces `Assignment` values stamped `kind: .quiz`, so one store and one
        // fetcher serve both kinds. The merge itself is the daemon's job now — it
        // fetches both routes per course and writes one list — which is why nothing
        // here fetches any more; what remains is the parser (a test helper against
        // recorded payloads) and `QuizLink`, the quiz deep-link template the
        // translation layer still picks per item.
        .target(
            name: "QuizPipeline",
            dependencies: ["AssignmentPipeline", "CoursePipeline"],
            path: "Modules/QuizPipeline/Sources"
        ),
        .testTarget(
            name: "QuizPipelineTests",
            dependencies: [
                "QuizPipeline", "AssignmentPipeline", "CoursePipeline",
            ],
            path: "Modules/QuizPipeline/Tests",
            // Fixtures are read via #filePath (see TestSupport.QuizFixture), not as
            // bundle resources. Excluding the whole directory also covers the README
            // documenting them, which SPM would otherwise reject as an unhandled
            // resource.
            exclude: ["Fixtures"]
        ),

        // ── The backend: work items the STUDENT typed in, not D2L ────────────
        //
        // Depends on CoursePipeline only for `DaemonPaths` — the file lives in
        // the same `$BSB_ROOT` the daemon owns, and two transcriptions of
        // `paths.mjs` would be two places to drift. The merge half is generic
        // over the fetched type, so nothing here names an adapter type.
        .target(
            name: "ManualItems",
            dependencies: ["CoursePipeline"],
            path: "Modules/ManualItems/Sources"
        ),
        .testTarget(
            name: "ManualItemsTests",
            dependencies: ["ManualItems", "CoursePipeline"],
            path: "Modules/ManualItems/Tests"
        ),

        // ── The contract between backend and GUI ─────────────────────────────
        .target(
            name: "CourseMenu",
            path: "Modules/CourseMenu/Sources"
        ),
        .testTarget(
            name: "CourseMenuTests",
            dependencies: ["CourseMenu"],
            path: "Modules/CourseMenu/Tests"
        ),

        // ── The wiring: [Course] → MenuModel, behind MenuDataSource ──────────
        .target(
            name: "MenuAdapter",
            // AssignmentPipeline is a genuine Sources dependency, not a test-only
            // one: `AssignmentsState` appears in `MenuTranslation.menu`'s public
            // signature, and `AssignmentTranslation` builds deep links with
            // `AssignmentLink`. QuizPipeline is here for the same reason — the
            // translation layer is the one place that chooses between the two
            // deep-link templates, so it needs `QuizLink`.
            dependencies: ["CourseMenu", "CoursePipeline", "AssignmentPipeline", "QuizPipeline"],
            path: "Modules/MenuAdapter/Sources"
        ),
        .testTarget(
            name: "MenuAdapterTests",
            dependencies: [
                "MenuAdapter", "CourseMenu", "CoursePipeline", "AssignmentPipeline",
            ],
            path: "Modules/MenuAdapter/Tests"
        ),

        // ── The GUI + composition root ───────────────────────────────────────
        .executableTarget(
            name: "BrightspaceBar",
            // The backend modules are here for main.swift ONLY; ArchitectureTests
            // fails the suite if any view file imports them.
            dependencies: [
                "CourseMenu", "MenuAdapter", "CoursePipeline", "AssignmentPipeline",
            ],
            path: "Modules/BrightspaceBar/Sources",
            exclude: ["Info.plist"],
            swiftSettings: [
                // Embeds Info.plist into the executable's __TEXT,__info_plist
                // section — RepoBar's trick. Without an Xcode project this is how
                // a plain SPM binary carries LSUIElement and a bundle identifier.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Modules/BrightspaceBar/Sources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "BrightspaceBarTests",
            // The backend modules are for GraphEndToEndTests ONLY, which drives
            // fixture bytes through the real parser → store → translation →
            // assembler chain. View files still cannot import them —
            // ArchitectureTests polices Sources/, and this is a test target.
            dependencies: [
                "BrightspaceBar", "CourseMenu", "MenuAdapter",
                "CoursePipeline", "AssignmentPipeline",
            ],
            path: "Modules/BrightspaceBar/Tests"
        ),
    ]
)
