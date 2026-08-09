import Foundation
@testable import RepoBar
import Testing

struct LocalRepoManagerTests {
    @Test
    func `snapshot respects max depth`() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let deepRepo = root
            .appendingPathComponent("level1", isDirectory: true)
            .appendingPathComponent("level2", isDirectory: true)
            .appendingPathComponent("level3", isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: deepRepo, withIntermediateDirectories: true)
        try initializeRepo(at: deepRepo)

        let manager = LocalRepoManager()
        let shallow = await manager.snapshot(
            rootPath: root.path,
            rootBookmarkData: nil,
            options: .init(
                autoSyncEnabled: false,
                fetchInterval: 0,
                preferredPathsByFullName: [:],
                matchRepoNames: [],
                forceRescan: true,
                maxDepth: 3
            )
        )
        #expect(shallow.discoveredCount == 0)

        let deep = await manager.snapshot(
            rootPath: root.path,
            rootBookmarkData: nil,
            options: .init(
                autoSyncEnabled: false,
                fetchInterval: 0,
                preferredPathsByFullName: [:],
                matchRepoNames: [],
                forceRescan: true,
                maxDepth: 4
            )
        )
        #expect(deep.discoveredCount == 1)
    }

    @Test
    func `snapshot skips cold refresh for non matching repos`() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let wanted = root.appendingPathComponent("wanted", isDirectory: true)
        let ignored = root.appendingPathComponent("ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try initializeRepo(at: wanted)
        try initializeRepo(at: ignored)

        let manager = LocalRepoManager()
        let snapshot = await manager.snapshot(
            rootPath: root.path,
            rootBookmarkData: nil,
            options: .init(
                autoSyncEnabled: false,
                fetchInterval: 0,
                preferredPathsByFullName: [:],
                matchRepoNames: ["wanted"],
                forceRescan: false,
                maxDepth: 1
            )
        )

        #expect(snapshot.discoveredCount == 2)
        #expect(snapshot.repoIndex.all.map(\.name) == ["wanted"])
    }
}

private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("repobar-localrepo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = directory
    process.arguments = arguments

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    try process.run()
    process.waitUntilExit()

    let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw GitTestError.commandFailed(arguments: arguments, output: output, error: error)
    }
    return output
}

private func initializeRepo(at url: URL) throws {
    try runGit(["init"], in: url)
}

private enum GitTestError: Error {
    case commandFailed(arguments: [String], output: String, error: String)
}
