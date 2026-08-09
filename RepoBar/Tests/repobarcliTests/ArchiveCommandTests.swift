import Commander
import Foundation
@testable import repobarcli
import Testing

struct ArchiveCommandTests {
    @Test
    func `archive add derives source from repository shorthand`() throws {
        let source = try ArchivesAddCommand.archiveSource(
            repository: "steipete/RepoBar",
            repoPath: nil,
            remoteURL: nil,
            branch: "",
            databasePath: nil
        )

        #expect(source.name == "steipete/RepoBar")
        #expect(source.remoteURL == "https://github.com/steipete/RepoBar.git")
        #expect(source.localRepositoryPath == nil)
        #expect(source.branch == "main")
        #expect(source.importedDatabasePath.contains("/RepoBar/Archives/steipete-repobar-"))
    }

    @Test
    func `archive add keeps legacy name when remote option is provided`() throws {
        let source = try ArchivesAddCommand.archiveSource(
            repository: "work snapshot",
            repoPath: nil,
            remoteURL: "https://github.com/steipete/RepoBar.git",
            branch: "main",
            databasePath: nil
        )

        #expect(source.name == "work snapshot")
        #expect(source.remoteURL == "https://github.com/steipete/RepoBar.git")
        #expect(source.localRepositoryPath == nil)
        #expect(source.importedDatabasePath.contains("/RepoBar/Archives/work-snapshot-"))
    }

    @Test
    func `archive add repo option accepts repository shorthand`() throws {
        let source = try ArchivesAddCommand.archiveSource(
            repository: nil,
            repoPath: "steipete/RepoBar",
            remoteURL: nil,
            branch: "main",
            databasePath: nil
        )

        #expect(source.name == "steipete/RepoBar")
        #expect(source.remoteURL == "https://github.com/steipete/RepoBar.git")
        #expect(source.localRepositoryPath == nil)
    }

    @Test
    func `archive add repo option accepts remote url`() throws {
        let source = try ArchivesAddCommand.archiveSource(
            repository: nil,
            repoPath: "https://github.com/steipete/RepoBar.git",
            remoteURL: nil,
            branch: "main",
            databasePath: nil
        )

        #expect(source.name == "steipete/RepoBar")
        #expect(source.remoteURL == "https://github.com/steipete/RepoBar.git")
        #expect(source.localRepositoryPath == nil)
    }

    @Test
    func `archive add rejects missing local repository path`() {
        #expect(throws: ValidationError.self) {
            _ = try ArchivesAddCommand.archiveSource(
                repository: nil,
                repoPath: "/tmp/repobar-missing-\(UUID().uuidString)",
                remoteURL: nil,
                branch: "main",
                databasePath: nil
            )
        }
    }

    @Test
    func `archive add rejects non git local repository path`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(throws: ValidationError.self) {
            _ = try ArchivesAddCommand.archiveSource(
                repository: nil,
                repoPath: tempDir.path,
                remoteURL: nil,
                branch: "main",
                databasePath: nil
            )
        }
    }

    @Test
    func `archive add accepts git working tree path`() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let source = try ArchivesAddCommand.archiveSource(
            repository: nil,
            repoPath: tempDir.path,
            remoteURL: nil,
            branch: "archive",
            databasePath: "~/archive.sqlite"
        )

        #expect(source.name == tempDir.lastPathComponent)
        #expect(source.localRepositoryPath == tempDir.path)
        #expect(source.remoteURL == nil)
        #expect(source.branch == "archive")
        #expect(source.importedDatabasePath.hasSuffix("/archive.sqlite"))
    }

    @Test
    func `archive add accepts missing remote clone target`() throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("repobar-missing-archive-\(UUID().uuidString)")

        let source = try ArchivesAddCommand.archiveSource(
            repository: "work snapshot",
            repoPath: missingPath.path,
            remoteURL: "https://github.com/steipete/RepoBar.git",
            branch: "main",
            databasePath: nil
        )

        #expect(source.name == "work snapshot")
        #expect(source.localRepositoryPath == missingPath.path)
        #expect(source.remoteURL == "https://github.com/steipete/RepoBar.git")
    }

    @Test
    func `archive add rejects malformed remote url`() {
        #expect(throws: ValidationError.self) {
            _ = try ArchivesAddCommand.archiveSource(
                repository: nil,
                repoPath: nil,
                remoteURL: "not-url",
                branch: "main",
                databasePath: nil
            )
        }
    }
}
