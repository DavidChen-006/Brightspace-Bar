import Foundation

struct Installation: Decodable {
    let id: Int
    let account: Account

    struct Account: Decodable {
        let login: String
        let url: URL?
    }
}
