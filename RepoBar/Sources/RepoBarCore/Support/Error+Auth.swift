import Foundation

public extension Error {
    var isAuthenticationFailure: Bool {
        if let gh = self as? GitHubAPIError {
            return gh.isAuthenticationFailure
        }
        if let urlError = self as? URLError, urlError.code == .userAuthenticationRequired {
            return true
        }
        return false
    }
}
