import XCTest
@testable import RepoBariOS

final class IncomingReferenceURLTests: XCTestCase {
    func testParsesResolveText() throws {
        let url = try XCTUnwrap(IncomingReferenceURL.makeURL(text: " openclaw/openclaw#123 "))

        XCTAssertEqual(IncomingReferenceURL.text(from: url), "openclaw/openclaw#123")
    }

    func testAcceptsURLQueryAlias() throws {
        let url = try XCTUnwrap(URL(string: "repobar://resolve?url=https%3A%2F%2Fgithub.com%2Fopenclaw%2Fopenclaw%2Fissues%2F76162"))

        XCTAssertEqual(
            IncomingReferenceURL.text(from: url),
            "https://github.com/openclaw/openclaw/issues/76162"
        )
    }

    func testRejectsNonResolveURLs() {
        XCTAssertNil(IncomingReferenceURL.text(from: URL(string: "https://github.com/openclaw/openclaw/issues/1")!))
        XCTAssertNil(IncomingReferenceURL.text(from: URL(string: "repobar://settings")!))
    }
}
