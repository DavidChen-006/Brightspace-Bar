import Foundation
import RepoBarCore
import Testing

struct PathFormatterCoverageTests {
    @Test
    func `expand tilde handles bare and subpaths`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PathFormatter.expandTilde("~") == home)
        #expect(PathFormatter.expandTilde("~/tmp").hasPrefix(home + "/"))
    }

    @Test
    func `abbreviate home falls back for non home paths`() {
        #expect(PathFormatter.abbreviateHome("/private/tmp") == "/private/tmp")
    }
}
