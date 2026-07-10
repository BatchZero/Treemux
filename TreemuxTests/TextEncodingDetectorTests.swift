import XCTest
@testable import Treemux

final class TextEncodingDetectorTests: XCTestCase {

    func testDetectsUTF8WithMultibyteContent() {
        let data = "中文 mixed ascii".data(using: .utf8)!
        let result = TextEncodingDetector.decode(data)
        XCTAssertEqual(result.text, "中文 mixed ascii")
        XCTAssertEqual(result.encoding, .utf8)
    }

    func testFallsBackToGB18030ForGBKBytes() {
        // "中文" in GB18030: D6 D0 CE C4 — invalid as UTF-8 (0xD0 is a lead
        // byte where a continuation byte is required).
        let data = Data([0xD6, 0xD0, 0xCE, 0xC4])
        let result = TextEncodingDetector.decode(data)
        XCTAssertEqual(result.text, "中文")
        XCTAssertNotEqual(result.encoding, .utf8)
        XCTAssertNotEqual(result.encoding, .isoLatin1)
    }

    func testFallsBackToLatin1ForBytesInvalidInBoth() {
        // 0xFF is not a valid GB18030 lead byte and not valid UTF-8.
        let data = Data([0xFF, 0xFE, 0xFF])
        let result = TextEncodingDetector.decode(data)
        XCTAssertEqual(result.encoding, .isoLatin1)
        XCTAssertEqual(result.text.count, 3)
    }

    func testEmptyDataIsUTF8EmptyString() {
        let result = TextEncodingDetector.decode(Data())
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.encoding, .utf8)
    }
}
