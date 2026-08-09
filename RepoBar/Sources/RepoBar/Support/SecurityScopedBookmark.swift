import Foundation

enum SecurityScopedBookmark {
    static func create(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    static func withAccess(to url: URL, rootBookmarkData: Data?, perform: () -> Void) {
        guard url.isFileURL else {
            perform()
            return
        }
        guard let rootBookmarkData,
              let scopedRoot = resolve(rootBookmarkData)
        else {
            perform()
            return
        }

        let rootURL = (scopedRoot as NSURL).filePathURL ?? scopedRoot
        let targetURL = (url as NSURL).filePathURL ?? url
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        let shouldAccess = targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
        guard shouldAccess else {
            perform()
            return
        }

        let didStart = scopedRoot.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                scopedRoot.stopAccessingSecurityScopedResource()
            }
        }
        perform()
    }
}
