import XCTest
@testable import Treemux

final class FileTreeSearchTests: XCTestCase {
    private func dir(_ path: String, _ name: String) -> FileNode {
        FileNode(id: path, name: name, path: path, kind: .directory, sizeBytes: nil, modifiedAt: nil)
    }
    private func file(_ path: String, _ name: String) -> FileNode {
        FileNode(id: path, name: name, path: path, kind: .file, sizeBytes: 1, modifiedAt: nil)
    }

    func testMatchesIsCaseInsensitiveSubstring() {
        XCTAssertTrue(FileTreeSearch.matches("ReadMe.md", query: "readme"))
        XCTAssertTrue(FileTreeSearch.matches("ReadMe.md", query: "me.m"))
        XCTAssertFalse(FileTreeSearch.matches("ReadMe.md", query: "xyz"))
    }

    func testFilterRevealsMatchAndAncestors() {
        // /r ├ src (dir) ├─ main.swift ; ├ notes.txt
        let root = [dir("/r/src", "src"), file("/r/notes.txt", "notes.txt")]
        let children = ["/r/src": [file("/r/src/main.swift", "main.swift")]]
        let (visible, expanded) = FileTreeSearch.filter(
            rootChildren: root, childrenByPath: children, query: "main")
        XCTAssertTrue(visible.contains("/r/src/main.swift"))
        XCTAssertTrue(visible.contains("/r/src"), "ancestor dir is visible")
        XCTAssertTrue(expanded.contains("/r/src"), "ancestor dir is force-expanded")
        XCTAssertFalse(visible.contains("/r/notes.txt"), "non-matching sibling hidden")
    }

    func testFilterMatchingDirectoryItselfIsVisibleNotForceExpanded() {
        let root = [dir("/r/src", "src")]
        let children = ["/r/src": [file("/r/src/a.txt", "a.txt")]]
        let (visible, expanded) = FileTreeSearch.filter(
            rootChildren: root, childrenByPath: children, query: "src")
        XCTAssertTrue(visible.contains("/r/src"))
        XCTAssertFalse(expanded.contains("/r/src"),
                       "a dir that matches by its own name isn't force-expanded")
    }
}
