import XCTest
@testable import Treemux

final class FileViewModeCodingTests: XCTestCase {
    func test_roundTripsAsRawString() throws {
        for mode in FileViewMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(FileViewMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func test_rawValuesAreStable() {
        XCTAssertEqual(FileViewMode.source.rawValue, "source")
        XCTAssertEqual(FileViewMode.split.rawValue, "split")
        XCTAssertEqual(FileViewMode.render.rawValue, "render")
    }
}
