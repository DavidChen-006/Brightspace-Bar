import Foundation
@testable import RepoBar
import Testing

struct RepoWebURLBuilderTests {
    @Test
    func `repo URL uses configured GitHub host`() throws {
        let host = try #require(URL(string: "https://github.example.com"))
        let builder = RepoWebURLBuilder(host: host)

        #expect(builder.repoURL(fullName: "acme/widget")?.absoluteString == "https://github.example.com/acme/widget")
    }

    @Test
    func `repo URL rejects malformed repository names`() throws {
        let host = try #require(URL(string: "https://github.com"))
        let builder = RepoWebURLBuilder(host: host)

        #expect(builder.repoURL(fullName: "widget") == nil)
        #expect(builder.repoURL(fullName: "acme/widget/extra") == nil)
    }
}
