import Commander
@testable import repobarcli
import Testing

struct CLIParsingTests {
    @Test
    func `parse repo name splits owner and name`() throws {
        let result = try parseRepoName("steipete/RepoBar")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name trims whitespace and git suffix`() throws {
        let result = try parseRepoName("  steipete/RepoBar.git  ")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name accepts GitHub HTTPS URLs`() throws {
        let result = try parseRepoName("https://github.com/steipete/RepoBar")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name accepts GitHub URL subpages`() throws {
        let result = try parseRepoName("https://github.com/steipete/RepoBar/issues/1")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name accepts SSH remotes`() throws {
        let result = try parseRepoName("git@github.com:steipete/RepoBar.git")
        #expect(result.owner == "steipete")
        #expect(result.name == "RepoBar")
    }

    @Test
    func `parse repo name rejects missing slash`() {
        #expect(throws: ValidationError.self) {
            _ = try parseRepoName("RepoBar")
        }
    }

    @Test
    func `parse repo name rejects extra raw path components`() {
        #expect(throws: ValidationError.self) {
            _ = try parseRepoName("steipete/RepoBar/issues/1")
        }
    }
}
