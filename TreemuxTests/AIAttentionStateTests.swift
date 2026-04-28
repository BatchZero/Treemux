import XCTest
@testable import Treemux

final class AIAttentionStateTests: XCTestCase {

    func testParseDoneTitle() {
        XCTAssertEqual(AIAttentionState.parse(notificationTitle: "treemux:done"), .done)
    }

    func testParseInputTitle() {
        XCTAssertEqual(AIAttentionState.parse(notificationTitle: "treemux:input"), .input)
    }

    func testParseUnrelatedTitleReturnsNil() {
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "Build finished"))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: ""))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "treemux:"))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "treemux:bogus"))
    }

    func testCaseInsensitivePrefixIsNotAccepted() {
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "TREEMUX:done"))
    }
}
