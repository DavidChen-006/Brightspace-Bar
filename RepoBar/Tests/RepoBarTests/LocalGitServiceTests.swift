import Foundation
@testable import RepoBarCore
import Testing

struct LocalGitServiceTests {
    @Test
    func `smart sync fast forwards behind repo`() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let origin = base.appendingPathComponent("origin.git", isDirectory: true)
        let repoA = base.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = base.appendingPathComponent("repo-b", isDirectory: true)

        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], in: base)
        _ = try runGit(["clone", origin.path, repoA.lastPathComponent], in: base)
        _ = try runGit(["clone", origin.path, repoB.lastPathComponent], in: base)

        try runGit(["switch", "-c", "main"], in: repoA)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repoA)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repoA)
        try Data("a\n".utf8).write(to: repoA.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repoA)
        try runGit(["commit", "-m", "init"], in: repoA)
        try runGit(["push", "-u", "origin", "main"], in: repoA)

        try runGit(["fetch", "origin", "main"], in: repoB)
        try runGit(["switch", "-c", "main", "--track", "origin/main"], in: repoB)
        try Data("a\nb\n".utf8).write(to: repoA.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repoA)
        try runGit(["commit", "-m", "next"], in: repoA)
        try runGit(["push"], in: repoA)

        let result = try LocalGitService().smartSync(at: repoB)
        #expect(result.didFetch == true)
        #expect(result.didPull == true)
    }

    @Test
    func `smart sync errors without upstream`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeRepo(at: repo)

        do {
            _ = try LocalGitService().smartSync(at: repo)
            #expect(Bool(false))
        } catch let error as LocalGitError {
            #expect(error == .missingUpstream)
        }
    }

    @Test
    func `rebase onto upstream errors when dirty`() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let origin = base.appendingPathComponent("origin.git", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], in: base)
        _ = try runGit(["clone", origin.path, repo.lastPathComponent], in: base)
        try runGit(["switch", "-c", "main"], in: repo)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repo)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repo)
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "init"], in: repo)
        try runGit(["push", "-u", "origin", "main"], in: repo)
        try Data("dirty\n".utf8).write(to: repo.appendingPathComponent("dirty.txt"), options: .atomic)

        do {
            try LocalGitService().rebaseOntoUpstream(at: repo)
            #expect(Bool(false))
        } catch let error as LocalGitError {
            #expect(error == .dirtyWorkingTree)
        }
    }

    @Test
    func `create branch creates and switches`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeRepo(at: repo)

        try LocalGitService().createBranch(at: repo, name: "feature/test")

        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branch == "feature/test")
    }

    @Test
    func `create worktree creates new worktree`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeRepo(at: repo)

        let worktree = root.appendingPathComponent("repo-worktree", isDirectory: true)
        try LocalGitService().createWorktree(at: repo, path: worktree, branch: "feature/worktree")

        #expect(FileManager.default.fileExists(atPath: worktree.path))
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branch == "feature/worktree")
    }

    @Test
    func `clone repo clones into destination`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let origin = root.appendingPathComponent("origin", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try initializeRepo(at: origin)

        let destination = root.appendingPathComponent("clone", isDirectory: true)
        let remoteURL = origin
        try LocalGitService().cloneRepo(remoteURL: remoteURL, to: destination)

        let isRepo = try runGit(["rev-parse", "--is-inside-work-tree"], in: destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(isRepo == "true")
    }

    @Test
    func `branches marks current branch`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeRepo(at: repo)

        try LocalGitService().createBranch(at: repo, name: "feature/test")

        let branches = try LocalGitService().branches(at: repo)
        let current = branches.first(where: \.isCurrent)?.name
        #expect(current == "feature/test")
        #expect(branches.contains(where: { $0.name == "main" }))
    }

    @Test
    func `worktrees parses detached entry`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeRepo(at: repo)

        let detached = root.appendingPathComponent("detached", isDirectory: true)
        try runGit(["worktree", "add", "--detach", detached.path], in: repo)

        let worktrees = try LocalGitService().worktrees(at: repo)
        let detachedEntry = worktrees.first { $0.path.standardizedFileURL == detached.standardizedFileURL }
        #expect(detachedEntry?.branch == nil)
        #expect(detachedEntry?.isCurrent == false)
        let hasCurrent = worktrees.contains(where: \.isCurrent)
        #expect(hasCurrent)
    }

    @Test
    func `hard reset to upstream discards local commit`() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let origin = base.appendingPathComponent("origin.git", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], in: base)
        _ = try runGit(["clone", origin.path, repo.lastPathComponent], in: base)
        try runGit(["switch", "-c", "main"], in: repo)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repo)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repo)
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "init"], in: repo)
        try runGit(["push", "-u", "origin", "main"], in: repo)

        try Data("local\n".utf8).write(to: repo.appendingPathComponent("local.txt"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "local"], in: repo)

        try LocalGitService().hardResetToUpstream(at: repo)

        let head = try runGit(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let upstream = try runGit(["rev-parse", "@{u}"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == upstream)
    }

    @Test
    func `smart sync errors when detached`() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeRepo(at: repo)
        _ = try runGit(["checkout", "--detach"], in: repo)

        do {
            _ = try LocalGitService().smartSync(at: repo)
            #expect(Bool(false))
        } catch let error as LocalGitError {
            #expect(error == .detachedHead)
        }
    }

    @Test
    func `smart sync pushes when ahead`() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let origin = base.appendingPathComponent("origin.git", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], in: base)
        _ = try runGit(["clone", origin.path, repo.lastPathComponent], in: base)
        try runGit(["switch", "-c", "main"], in: repo)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repo)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repo)
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "init"], in: repo)
        try runGit(["push", "-u", "origin", "main"], in: repo)

        try Data("b\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "next"], in: repo)

        let result = try LocalGitService().smartSync(at: repo)
        #expect(result.didPush == true)
    }

    @Test
    func `branch details reports upstream and ahead`() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let origin = base.appendingPathComponent("origin.git", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], in: base)
        _ = try runGit(["clone", origin.path, repo.lastPathComponent], in: base)
        try runGit(["switch", "-c", "main"], in: repo)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repo)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repo)
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "init"], in: repo)
        try runGit(["push", "-u", "origin", "main"], in: repo)

        try Data("b\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "next"], in: repo)

        let snapshot = try LocalGitService().branchDetails(at: repo)
        let main = snapshot.branches.first { $0.name == "main" }
        #expect(main?.upstream != nil)
        #expect((main?.aheadCount ?? 0) > 0)
        #expect(main?.lastCommitAuthor == "RepoBar Tests")
    }

    @Test
    func `worktrees include metadata`() throws {
        let base = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let origin = base.appendingPathComponent("origin.git", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "--bare", origin.path], in: base)
        _ = try runGit(["clone", origin.path, repo.lastPathComponent], in: base)
        try runGit(["switch", "-c", "main"], in: repo)
        try runGit(["config", "user.email", "repobar-tests@example.com"], in: repo)
        try runGit(["config", "user.name", "RepoBar Tests"], in: repo)
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("README.md"), options: .atomic)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-m", "init"], in: repo)
        try runGit(["push", "-u", "origin", "main"], in: repo)

        let worktrees = try LocalGitService().worktrees(at: repo)
        let current = worktrees.first(where: \.isCurrent)
        #expect(current?.branch == "main")
        #expect(current?.upstream != nil)
        #expect(current?.lastCommitAuthor == "RepoBar Tests")
    }
}

private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("repobar-localgit-\(UUID().uuidString)", isDirectory: true)
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
    try runGit(["switch", "-c", "main"], in: url)
    try runGit(["config", "user.email", "repobar-tests@example.com"], in: url)
    try runGit(["config", "user.name", "RepoBar Tests"], in: url)
    let readme = url.appendingPathComponent("README.md")
    try Data("test\n".utf8).write(to: readme, options: .atomic)
    try runGit(["add", "."], in: url)
    try runGit(["commit", "-m", "init"], in: url)
}

private enum GitTestError: Error {
    case commandFailed(arguments: [String], output: String, error: String)
}
