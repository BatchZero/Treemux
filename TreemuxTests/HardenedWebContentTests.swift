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

    // MARK: - Fix 1: regex head-tag matching

    func test_cspInjectedIntoHeadWithAttributes() {
        let input = #"<html><head data-x="y"><title>t</title></head><body>hi</body></html>"#
        let out = HardenedWebContent.cspWrapped(input)
        XCTAssertTrue(out.contains("Content-Security-Policy"), "CSP must be injected")
        // CSP must appear after the opening <head ...> tag
        if let headRange = out.range(of: #"<head[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let cspRange = out.range(of: "Content-Security-Policy") {
            XCTAssertTrue(cspRange.lowerBound >= headRange.upperBound,
                          "CSP must appear after the <head> opening tag")
        } else {
            XCTFail("Could not find head tag or CSP in output")
        }
    }

    func test_cspInjectedIntoHeadUppercase() {
        let input = "<HTML><HEAD><title>t</title></HEAD><BODY>hi</BODY></HTML>"
        let out = HardenedWebContent.cspWrapped(input)
        XCTAssertTrue(out.contains("Content-Security-Policy"), "CSP must be injected for uppercase HEAD")
        XCTAssertTrue(out.contains("default-src 'none'"))
    }

    func test_cspInjectedIntoHeadWithTrailingSpace() {
        let input = "<html><head ><title>t</title></head><body>hi</body></html>"
        let out = HardenedWebContent.cspWrapped(input)
        XCTAssertTrue(out.contains("Content-Security-Policy"), "CSP must be injected for <head > with trailing space")
        XCTAssertTrue(out.contains("default-src 'none'"))
    }
}
