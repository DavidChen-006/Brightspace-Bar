@testable import RepoBar
@testable import RepoBarCore
import Testing

struct PKCETests {
    @Test
    func `verifier and challenge not empty`() {
        let pkce = PKCE.generate()
        #expect(!pkce.verifier.isEmpty)
        #expect(!pkce.challenge.isEmpty)
    }
}
