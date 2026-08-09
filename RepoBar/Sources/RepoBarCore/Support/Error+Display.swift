import Foundation

public extension Error {
    var userFacingMessage: String {
        if let decodingError = self as? DecodingError {
            return decodingError.userFacingMessage
        }
        if let ghError = self as? GitHubAPIError {
            return ghError.displayMessage
        }
        if let urlError = self as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "No internet connection."
            case .timedOut: return "Request timed out."
            case .cannotLoadFromNetwork: return "Rate limited; retry soon."
            case .cannotParseResponse: return "GitHub returned an unexpected response."
            case .userAuthenticationRequired: return "Authentication required. Please sign in again."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                return "Enterprise host certificate is not trusted."
            default: break
            }
        }
        return localizedDescription
    }
}

private extension DecodingError {
    var userFacingMessage: String {
        switch self {
        case let .keyNotFound(key, _):
            return "Response missing expected field '\(key.stringValue)'. Try again or update RepoBar."
        case .valueNotFound:
            return "Response missing expected data. Try again or update RepoBar."
        case .typeMismatch:
            return "Response had unexpected data. Try again or update RepoBar."
        case .dataCorrupted:
            return "Response was malformed. Try again or update RepoBar."
        @unknown default:
            return "Response could not be decoded. Try again or update RepoBar."
        }
    }
}
