import Foundation
import Security

/// Minimal RS256 JWT signer for GitHub App authentication.
enum JWTSigner {
    enum Error: Swift.Error {
        case invalidPEM
        case keyCreationFailed
        case signFailed
    }

    static func sign(appID: String, pemString: String, now: Date = Date()) throws -> String {
        let keyData = try self.derData(fromPEM: pemString)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        guard let secKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil)
        else { throw Error.keyCreationFailed }

        let header = ["alg": "RS256", "typ": "JWT"]
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 8 * 60 + 30 // <=10 minutes; use 8.5 to be safe
        let payload: [String: Any] = ["iat": iat, "exp": exp, "iss": appID]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let signingInput = [
            headerData.base64URLEncodedString(),
            payloadData.base64URLEncodedString()
        ].joined(separator: ".")

        guard let messageData = signingInput.data(using: .utf8) else { throw Error.signFailed }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            messageData as CFData,
            &error
        ) as Data?
        else { throw error?.takeRetainedValue() ?? Error.signFailed }

        return signingInput + "." + signature.base64URLEncodedString()
    }

    private static func derData(fromPEM pem: String) throws -> Data {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: stripped) else { throw Error.invalidPEM }

        return data
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
