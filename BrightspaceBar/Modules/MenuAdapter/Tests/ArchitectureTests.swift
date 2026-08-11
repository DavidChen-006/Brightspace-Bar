import Foundation
import Testing

// ═════════════════════════════════════════════════════════════════════════════
// Architecture — the rules Swift cannot express, enforced by reading source.
//
// PRIORITY: keeping the contract a contract. The entire value of `CourseMenu` is
// that the GUI cannot see backend types, which is what let the frontend be built
// and tested before any wiring existed. That guarantee used to be enforced by
// `Package.swift` — the GUI simply had no access. Phase 3 spent it: the composition
// root must see both sides to wire them together, so `BrightspaceBar` now depends
// on `MenuAdapter` and can therefore reach `CoursePipeline` transitively.
//
// SPM dependencies are per-target, not per-file, so nothing stops a later edit from
// importing `CoursePipeline` inside a view file and quietly reintroducing exactly
// the coupling this design exists to prevent. It would compile, ship, and pass every
// other test in this package.
//
// These tests are the replacement guarantee. They read the source directory and
// check import lines. Crude, and the only mechanism available.
//
// SCOPE: small. Reads files from the repository, no network, no build products.
// ═════════════════════════════════════════════════════════════════════════════

/// Locates source directories by walking up from this test file, so the checks work
/// regardless of the working directory `swift test` was invoked from.
private enum Layout {
    /// `<package root>` — four parents up from `Modules/MenuAdapter/Tests/<this file>`.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Modules/MenuAdapter/Tests
            .deletingLastPathComponent()   // Modules/MenuAdapter
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // <package root>
            .standardizedFileURL
    }

    static var guiSources: URL { self.packageRoot.appending(path: "Modules/BrightspaceBar/Sources") }
    static var contractSources: URL { self.packageRoot.appending(path: "Modules/CourseMenu/Sources") }

    /// Every `.swift` file directly under `directory`, recursively.
    static func swiftFiles(in directory: URL) throws -> [URL] {
        let all = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        return all
            .filter { $0.hasSuffix(".swift") }
            .map { directory.appending(path: $0) }
            .sorted { $0.path < $1.path }
    }

    /// The modules a file imports. Matches `import Foo` and `@_exported import Foo`,
    /// ignoring anything inside a comment-only line.
    static func imports(of file: URL) throws -> [String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { return nil }
            guard let range = line.range(of: #"^(@_exported\s+)?import\s+"#, options: .regularExpression)
            else { return nil }
            // Take the first path component: `import A.B` counts as importing `A`.
            return line[range.upperBound...]
                .split(separator: ".").first?
                .trimmingCharacters(in: .whitespaces)
        }
    }
}

@Suite("Architecture — the contract stays a contract")
struct ArchitectureTests {

    /// Backend modules. View code may not name any of them — `BrightspaceSession`
    /// included: a view file holding a credential type is exactly the leak this
    /// suite exists to prevent.
    private static let backendModules: Set<String> = [
        "MenuAdapter", "CoursePipeline", "AssignmentPipeline", "QuizPipeline",
        "BrightspaceSession",
    ]

    /// The single exemption: the composition root exists precisely to know both
    /// sides, and there is no way to wire two halves together while seeing only one.
    private static let compositionRoot = "main.swift"

    @Test("the architecture scan actually finds source files")
    func theScanIsNotVacuous() throws {
        // Arrange / Act — a glob that silently matches nothing would make every
        // other test in this suite pass while checking nothing at all. This is the
        // guard that makes the rest meaningful.
        let gui = try Layout.swiftFiles(in: Layout.guiSources)
        let contract = try Layout.swiftFiles(in: Layout.contractSources)

        // Assert
        #expect(gui.count >= 2, "expected several GUI sources, found \(gui.count)")
        #expect(!contract.isEmpty, "found no contract sources")
        #expect(
            gui.contains { $0.lastPathComponent == Self.compositionRoot },
            "no \(Self.compositionRoot) — either it was renamed, or the scan is looking in the wrong place"
        )
    }

    @Test("no view file imports a backend module")
    func viewCodeCannotSeeTheBackend() throws {
        // Arrange
        let files = try Layout.swiftFiles(in: Layout.guiSources)
            .filter { $0.lastPathComponent != Self.compositionRoot }
        try #require(!files.isEmpty, "no view files to check")

        // Act / Assert — reported per file so a failure names the culprit rather
        // than just saying the rule broke.
        for file in files {
            let offending = Set(try Layout.imports(of: file)).intersection(Self.backendModules)
            #expect(
                offending.isEmpty,
                """
                \(file.lastPathComponent) imports \(offending.sorted().joined(separator: ", ")).
                View code must depend on CourseMenu only; the composition root \
                (\(Self.compositionRoot)) is the one place allowed to see both sides. \
                Move the wiring there and pass a `MenuDataSource` in.
                """
            )
        }
    }

    @Test("the composition root is the only file that wires the two sides together")
    func exactlyOneFileKnowsBothSides() throws {
        // Arrange
        let files = try Layout.swiftFiles(in: Layout.guiSources)

        // Act
        let knowBoth = try files.filter { file in
            !Set(try Layout.imports(of: file)).intersection(Self.backendModules).isEmpty
        }

        // Assert — the positive half of the rule. `main.swift` SHOULD import the
        // adapter; if nothing does, the app is still running on stubs and phase 3
        // is not actually wired, which no other test in this package would catch.
        #expect(
            knowBoth.map(\.lastPathComponent) == [Self.compositionRoot],
            "files importing a backend module: \(knowBoth.map(\.lastPathComponent).sorted())"
        )
    }

    @Test("the contract module depends on nothing but Foundation")
    func theContractStaysPure() throws {
        // Arrange — `CourseMenu` is shared by both sides, so anything it imports is
        // imposed on both. AppKit would make it untestable headless and unusable
        // from a non-GUI client; CoursePipeline would collapse the whole separation.
        let files = try Layout.swiftFiles(in: Layout.contractSources)
        try #require(!files.isEmpty)
        let allowed: Set<String> = ["Foundation", "Synchronization"]

        // Act / Assert
        for file in files {
            let unexpected = Set(try Layout.imports(of: file)).subtracting(allowed)
            let names = unexpected.sorted().joined(separator: ", ")
            #expect(
                unexpected.isEmpty,
                "\(file.lastPathComponent) imports \(names) — the contract must stay values-only"
            )
        }
    }
}
