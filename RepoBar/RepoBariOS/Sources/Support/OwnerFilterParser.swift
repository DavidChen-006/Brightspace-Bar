import Foundation

enum OwnerFilterParser {
    static func parse(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    static func format(_ owners: [String]) -> String {
        owners.joined(separator: ", ")
    }
}
