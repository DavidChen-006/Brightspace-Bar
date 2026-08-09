import Foundation
import RepoBarCore
import Testing

struct ErrorDisplayCoverageTests {
    @Test
    func `url error messages cover common cases`() {
        #expect(URLError(.notConnectedToInternet).userFacingMessage == "No internet connection.")
        #expect(URLError(.timedOut).userFacingMessage == "Request timed out.")
        #expect(URLError(.cannotLoadFromNetwork).userFacingMessage == "Rate limited; retry soon.")
        #expect(URLError(.cannotParseResponse).userFacingMessage == "GitHub returned an unexpected response.")
        #expect(URLError(.userAuthenticationRequired).userFacingMessage == "Authentication required. Please sign in again.")
        #expect(URLError(.serverCertificateUntrusted).userFacingMessage == "Enterprise host certificate is not trusted.")
    }

    @Test
    func `github error uses display message`() {
        let error: Error = GitHubAPIError.badStatus(code: 500, message: nil)
        #expect(error.userFacingMessage == "GitHub returned 500.")
    }

    @Test
    func `fallback returns localized description`() {
        struct TestError: LocalizedError { var errorDescription: String? {
            "boom"
        } }
        let error: Error = TestError()
        #expect(error.userFacingMessage == "boom")
    }
}
