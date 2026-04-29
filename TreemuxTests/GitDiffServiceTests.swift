import XCTest
@testable import Treemux

final class GitDiffServiceTests: XCTestCase {
    func test_parseDiff_detectsAddedHunk() {
        let raw = """
        diff --git a/foo.swift b/foo.swift
        index 1234..5678 100644
        --- a/foo.swift
        +++ b/foo.swift
        @@ -10,3 +10,5 @@ class Foo {
             let a = 1
        +    let b = 2
        +    let c = 3
             let d = 4
        """
        let hunks = LocalGitDiffService.parseDiff(raw)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].kind, .modified)
        XCTAssertTrue(hunks[0].newLineRange.contains(11))
    }

    func test_parseDiff_handlesMultipleHunks() {
        let raw = """
        @@ -1,2 +1,3 @@
        +new line
         existing
         existing
        @@ -50,3 +51,2 @@
         a
         b
        -removed
        """
        let hunks = LocalGitDiffService.parseDiff(raw)
        XCTAssertEqual(hunks.count, 2)
    }

    func test_parseStatus_classifiesPorcelainCodes() {
        let raw = """
         M Sources/Foo.swift
        ?? Sources/Bar.swift
        A  Sources/Baz.swift
        D  Sources/Old.swift
        """
        let status = LocalGitDiffService.parseStatus(raw)
        XCTAssertEqual(status["Sources/Foo.swift"], .modified)
        XCTAssertEqual(status["Sources/Bar.swift"], .untracked)
        XCTAssertEqual(status["Sources/Baz.swift"], .added)
        XCTAssertEqual(status["Sources/Old.swift"], .deleted)
    }

    func test_parseStatus_handlesRenames() {
        let raw = """
        R  Sources/Old.swift -> Sources/New.swift
        """
        let status = LocalGitDiffService.parseStatus(raw)
        XCTAssertEqual(status["Sources/New.swift"], .renamed(from: "Sources/Old.swift"))
    }

    func test_parseStatus_emptyInput() {
        XCTAssertEqual(LocalGitDiffService.parseStatus(""), [:])
    }
}
