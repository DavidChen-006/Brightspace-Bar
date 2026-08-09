import Foundation

public enum OAuthFormEncoder {
    public static func encode(_ params: [String: String]) -> Data? {
        let encoded = params
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { key, value in
                "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
            }
            .joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            .replacingOccurrences(of: "%20", with: "+")
    }
}
