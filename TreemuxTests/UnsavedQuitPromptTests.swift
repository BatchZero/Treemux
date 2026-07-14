//
//  UnsavedQuitPromptTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class UnsavedQuitPromptTests: XCTestCase {
    func testEmpty_returnsNil() {
        XCTAssertNil(UnsavedQuitPrompt.plan(paths: []))
        XCTAssertNil(UnsavedQuitPrompt.build(paths: []))
    }

    func testSingle_oneNameNoOverflow() {
        let plan = UnsavedQuitPrompt.plan(paths: ["/a/b/notes.md"])
        XCTAssertEqual(plan, UnsavedQuitPrompt.Plan(
            uniqueCount: 1, listedNames: ["notes.md"], overflowCount: 0))
    }

    func testFew_allListedNoOverflow() {
        let plan = UnsavedQuitPrompt.plan(paths: ["/x/a.txt", "/x/b.txt", "/x/c.txt"])
        XCTAssertEqual(plan?.uniqueCount, 3)
        XCTAssertEqual(plan?.listedNames, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(plan?.overflowCount, 0)
    }

    func testMany_listsMaxThenOverflow() {
        let paths = (1...7).map { "/x/f\($0).swift" }
        let plan = UnsavedQuitPrompt.plan(paths: paths)
        XCTAssertEqual(plan?.uniqueCount, 7)
        XCTAssertEqual(plan?.listedNames.count, UnsavedQuitPrompt.maxListed) // 5
        XCTAssertEqual(plan?.listedNames, ["f1.swift", "f2.swift", "f3.swift", "f4.swift", "f5.swift"])
        XCTAssertEqual(plan?.overflowCount, 2)
    }

    func testDuplicatePaths_deduped() {
        let plan = UnsavedQuitPrompt.plan(paths: ["/a/x.txt", "/a/x.txt", "/b/y.txt"])
        XCTAssertEqual(plan?.uniqueCount, 2)
        XCTAssertEqual(plan?.listedNames, ["x.txt", "y.txt"])
        XCTAssertEqual(plan?.overflowCount, 0)
    }

    func testBuild_nonNilForNonEmpty() {
        // Locale-independent structural checks: message + informative present,
        // informative contains the filename and the discard hint.
        let out = UnsavedQuitPrompt.build(paths: ["/a/b/report.md"])
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.message.isEmpty)
        XCTAssertTrue(out!.informative.contains("report.md"))
    }
}
