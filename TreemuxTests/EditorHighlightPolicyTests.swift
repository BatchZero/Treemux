//
//  EditorHighlightPolicyTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class EditorHighlightPolicyTests: XCTestCase {
    func test_smallKnownLanguageFile_isHighlighted() {
        XCTAssertTrue(EditorHighlightPolicy.shouldHighlight(path: "/r/a.swift", byteCount: 1_000))
    }

    func test_fileAtLimit_isHighlighted() {
        XCTAssertTrue(
            EditorHighlightPolicy.shouldHighlight(path: "/r/a.swift",
                                                  byteCount: EditorHighlightPolicy.highlightSizeLimit))
    }

    func test_fileOverLimit_isNotHighlighted() {
        XCTAssertFalse(
            EditorHighlightPolicy.shouldHighlight(path: "/r/a.swift",
                                                  byteCount: EditorHighlightPolicy.highlightSizeLimit + 1))
    }

    func test_unknownLanguage_isNotHighlighted() {
        XCTAssertFalse(EditorHighlightPolicy.shouldHighlight(path: "/r/notes.unknownext", byteCount: 10))
    }
}
