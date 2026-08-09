import Foundation

enum GitHubPagination {
    static func lastPage(from linkHeader: String) -> Int? {
        // Example: <https://api.github.com/repositories/1300192/pulls?state=open&per_page=1&page=2>; rel="next",
        //          <https://api.github.com/repositories/1300192/pulls?state=open&per_page=1&page=4>; rel="last"
        for part in linkHeader.split(separator: ",") {
            let segments = part.split(separator: ";")
            guard segments.contains(where: { $0.contains("rel=\"last\"") }) else { continue }

            let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
            let trimmed = urlPart.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard let components = URLComponents(string: trimmed),
                  let page = components.queryItems?.first(where: { $0.name == "page" })?.value,
                  let pageNumber = Int(page) else { continue }

            return pageNumber
        }
        return nil
    }
}
