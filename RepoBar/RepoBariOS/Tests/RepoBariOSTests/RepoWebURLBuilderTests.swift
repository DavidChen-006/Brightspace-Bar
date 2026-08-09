@testable import RepoBariOS
import Foundation
import Testing

struct RepoWebURLBuilderTests {
    private func builder(host: String = "https://github.com") throws -> RepoWebURLBuilder {
        let url = try #require(URL(string: host))
        return RepoWebURLBuilder(host: url)
    }

    @Test
    func test_buildsRepoURL() throws {
        let builder = try self.builder(host: "https://github.example.com")
        #expect(
            builder.repoURL(fullName: "acme/widget")?.absoluteString
                == "https://github.example.com/acme/widget"
        )
    }

    @Test
    func test_rejectsMalformedRepositoryNames() throws {
        let builder = try self.builder()

        #expect(builder.repoURL(fullName: "widget") == nil)
        #expect(builder.repoURL(fullName: "acme/widget/extra") == nil)
        #expect(builder.repoURL(fullName: "acme//widget") == nil)
        #expect(builder.repoURL(fullName: "acme/widget/") == nil)
        #expect(builder.repoURL(fullName: "acme//") == nil)
        #expect(builder.repoURL(fullName: "/widget") == nil)
        #expect(builder.repoURL(fullName: "") == nil)
    }
}
