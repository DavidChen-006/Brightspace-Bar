import XCTest
@testable import RepoBariOS

final class OwnerFilterParserTests: XCTestCase {
    func testParsesCommaSeparatedOwners() {
        XCTAssertEqual(
            OwnerFilterParser.parse(" openclaw, steipete, "),
            ["openclaw", "steipete"]
        )
    }

    func testFormatsOwnersForDisplay() {
        XCTAssertEqual(
            OwnerFilterParser.format(["openclaw", "steipete"]),
            "openclaw, steipete"
        )
    }
}
