import XCTest
@testable import Treemux

final class RenderedDocumentPolicyTests: XCTestCase {
    func test_markdownExtensions() {
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/README.md"), .markdown)
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/NOTES.markdown"), .markdown)
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/Doc.MD"), .markdown)
    }

    func test_htmlExtensions() {
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/index.html"), .html)
        XCTAssertEqual(RenderedDocumentPolicy.renderKind(forPath: "/a/page.htm"), .html)
    }

    func test_nonRenderable() {
        XCTAssertNil(RenderedDocumentPolicy.renderKind(forPath: "/a/main.swift"))
        XCTAssertNil(RenderedDocumentPolicy.renderKind(forPath: "/a/file.txt"))
    }

    func test_defaultModes() {
        XCTAssertEqual(RenderedDocumentPolicy.defaultMode(for: .markdown), .split)
        XCTAssertEqual(RenderedDocumentPolicy.defaultMode(for: .html), .source)
    }

    func test_linkSchemeAllowList() {
        XCTAssertTrue(RenderedDocumentPolicy.isAllowedLinkScheme("https"))
        XCTAssertTrue(RenderedDocumentPolicy.isAllowedLinkScheme("HTTP"))
        XCTAssertTrue(RenderedDocumentPolicy.isAllowedLinkScheme("mailto"))
        XCTAssertFalse(RenderedDocumentPolicy.isAllowedLinkScheme("javascript"))
        XCTAssertFalse(RenderedDocumentPolicy.isAllowedLinkScheme("file"))
        XCTAssertFalse(RenderedDocumentPolicy.isAllowedLinkScheme(nil))
    }
}
