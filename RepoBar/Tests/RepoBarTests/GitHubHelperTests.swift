import Foundation
@testable import RepoBarCore
import Testing

struct GitHubHelperTests {
    @Test
    func `parses link header last page`() {
        let link = "<https://api.github.com/repositories/1300192/pulls?state=open&per_page=1&page=2>; rel=\"next\", <https://api.github.com/repositories/1300192/pulls?state=open&per_page=1&page=4>; rel=\"last\""
        #expect(GitHubPagination.lastPage(from: link) == 4)
    }

    @Test
    func `ci status prefers conclusion`() {
        #expect(GitHubStatusMapper.ciStatus(fromStatus: "queued", conclusion: "success") == .passing)
        #expect(GitHubStatusMapper.ciStatus(fromStatus: "queued", conclusion: "failure") == .failing)
        #expect(GitHubStatusMapper.ciStatus(fromStatus: "in_progress", conclusion: nil) == .pending)
        #expect(GitHubStatusMapper.ciStatus(fromStatus: nil, conclusion: nil) == .unknown)
    }
}
