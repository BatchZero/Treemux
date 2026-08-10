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

    func test_markdownProviderRequiresMarkdownAndHighlightEligibility() {
        XCTAssertTrue(
            EditorHighlightPolicy.shouldUseMarkdownProvider(
                isMarkdown: true,
                highlightEligible: true
            )
        )
        XCTAssertFalse(
            EditorHighlightPolicy.shouldUseMarkdownProvider(
                isMarkdown: true,
                highlightEligible: false
            )
        )
        XCTAssertFalse(
            EditorHighlightPolicy.shouldUseMarkdownProvider(
                isMarkdown: false,
                highlightEligible: true
            )
        )
    }
}
