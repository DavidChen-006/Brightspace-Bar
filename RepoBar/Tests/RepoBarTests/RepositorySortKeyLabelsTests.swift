@testable import RepoBar
import RepoBarCore
import Testing

struct RepositorySortKeyLabelsTests {
    @Test
    func `menu sort symbols stay compact`() {
        #expect(RepositorySortKey.menuCases == [.activity, .issues, .pulls, .stars, .name])
        #expect(RepositorySortKey.name.menuSymbolName == "textformat")
        #expect(RepositorySortKey.menuCases.allSatisfy { !$0.menuSymbolName.contains("abc") })
    }
}
