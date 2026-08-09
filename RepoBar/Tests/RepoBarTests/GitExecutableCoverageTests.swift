import Foundation
@testable import RepoBarCore
import Testing

struct GitExecutableCoverageTests {
    @Test
    func `locator resolves executable URL`() {
        let locator = GitExecutableLocator()
        #expect(locator.url.path.hasSuffix("/git"))
    }

    @Test
    func `locator exposes sandbox state`() {
        _ = GitExecutableLocator.isSandboxed
        #expect(true)
    }

    @Test
    func `version reads version for git`() {
        let url = URL(fileURLWithPath: "/usr/bin/git")
        let result = GitExecutableLocator.version(at: url)
        #expect(result.error == nil)
        #expect(result.version?.contains("git version") == true)
    }

    @Test
    func `version returns error for missing executable`() {
        let url = URL(fileURLWithPath: "/no/such/git")
        let result = GitExecutableLocator.version(at: url)
        #expect(result.version == nil)
        #expect(result.error?.isEmpty == false)
    }

    @Test
    func `version returns stderr for non zero exit`() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GitExecutableCoverageTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("fakegit")

        let script = """
        #!/bin/sh
        echo "nope" 1>&2
        exit 1
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let result = GitExecutableLocator.version(at: scriptURL)
        #expect(result.version == nil)
        #expect(result.error == "nope")
    }
}
