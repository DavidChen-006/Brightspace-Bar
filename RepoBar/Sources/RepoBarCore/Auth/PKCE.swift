import CryptoKit
import Foundation

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public static func generate() -> PKCE {
        // RFC 7636: code_verifier 43-128 chars of unreserved; use 32 bytes base64url
        var data = Data(count: 32)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let verifier = data.base64URLEncodedString()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
