import XCTest
@testable import Treemux

final class HardenedWebContentTests: XCTestCase {
    func test_cspInjectedIntoHead() {
        let out = HardenedWebContent.cspWrapped("<html><head><title>x</title></head><body>hi</body></html>")
        XCTAssertTrue(out.contains("Content-Security-Policy"))
        XCTAssertTrue(out.contains("default-src 'none'"))
        XCTAssertTrue(out.contains("img-src data:"))
    }

    func test_cspInjectedWhenNoHead() {
        let out = HardenedWebContent.cspWrapped("<body>hi</body>")
        XCTAssertTrue(out.contains("Content-Security-Policy"))
        XCTAssertTrue(out.contains("hi"))
    }

    func test_ruleListBlocksAll() {
        XCTAssertTrue(HardenedWebContent.egressBlockRuleListJSON.contains("block"))
        XCTAssertTrue(HardenedWebContent.egressBlockRuleListJSON.contains(".*"))
    }
}
