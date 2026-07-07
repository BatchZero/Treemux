//
//  EditorBufferIsolationTests.swift
//  TreemuxTests

import XCTest
import Combine
@testable import Treemux

@MainActor
final class EditorBufferIsolationTests: XCTestCase {
    // Reuse the temp-tree + controller fixture pattern from
    // FileBrowserTabControllerTests: create a temp dir with one text file,
    // loadRoot, open the file so a .text sub-tab exists.
    private func makeControllerWithOpenFile() async throws -> (FileBrowserTabController, UUID) {
        let root = NSTemporaryDirectory() + "bufiso-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/a.txt", contents: Data("hello".utf8))
        let c = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: LocalFileBrowserDataSource()
        )
        await c.loadRoot()
        await c.openInTree(root + "/a.txt")
        let id = try XCTUnwrap(c.activeSubTabID)
        return (c, id)
    }

    func testKeystrokesPublishOnlyOnDirtyTransition() async throws {
        let (c, id) = try await makeControllerWithOpenFile()
        var publishes = 0
        let sub = c.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        c.updateBuffer(content: "hello1", forSubTab: id)   // dirty flips: 1 publish
        let afterFirst = publishes
        XCTAssertGreaterThan(afterFirst, 0)
        c.updateBuffer(content: "hello12", forSubTab: id)  // already dirty: no publish
        c.updateBuffer(content: "hello123", forSubTab: id)
        XCTAssertEqual(publishes, afterFirst, "subsequent keystrokes must not publish")
        XCTAssertEqual(c.liveBuffer(for: id), "hello123")
    }

    func testSavePersistsLiveBufferAndClearsDirty() async throws {
        let (c, id) = try await makeControllerWithOpenFile()
        c.updateBuffer(content: "changed", forSubTab: id)
        try await c.saveCurrentFile()
        if case .text(let path, let content, _, let dirty) = c.openFile {
            XCTAssertEqual(content, "changed")
            XCTAssertFalse(dirty)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "changed")
        } else {
            XCTFail("expected .text open file")
        }
    }

    /// Semantic red line: switching away from a dirty sub-tab and back must not
    /// lose the in-progress edit. `openFile.content` intentionally stays pinned
    /// at the value it had when the tab was opened/last saved (that's the whole
    /// point of the isolation), so any view that reconstructs its initial text
    /// from "controller state for this sub-tab" must consult
    /// `liveBuffer(for:) ?? openFile.content`, not `openFile.content` alone.
    func testLiveBufferSurvivesSubTabSwitchRoundTrip() async throws {
        let (c, id) = try await makeControllerWithOpenFile()
        // Pin the tab first: an unpinned (preview) tab gets repurposed in place
        // when the user opens a different file, which would legitimately drop
        // its live buffer (see the openInTree cleanup). Pinning is what keeps
        // the second `openInTree` below from touching this sub-tab at all, so
        // the test actually exercises "switch away and back," not "repurpose."
        c.pinActiveSubTab()
        c.updateBuffer(content: "hello1", forSubTab: id)
        c.updateBuffer(content: "hello12", forSubTab: id)

        // Open a second file so there is somewhere else to switch to.
        let root = URL(fileURLWithPath: c.rootPath).path
        FileManager.default.createFile(atPath: root + "/b.txt", contents: Data("b".utf8))
        await c.openInTree(root + "/b.txt")
        let otherID = try XCTUnwrap(c.activeSubTabID)
        XCTAssertNotEqual(otherID, id)

        // Switch back to the original sub-tab.
        c.activateSubTab(id)
        XCTAssertEqual(c.activeSubTabID, id)

        // openFile.content is intentionally stale (still "hello", the opened
        // value); the live buffer is where the in-progress edit lives, and it
        // must have survived the round trip untouched.
        guard case .text(_, let openedContent, _, let dirty) = c.openFile else {
            XCTFail("expected .text open file")
            return
        }
        XCTAssertTrue(dirty)
        XCTAssertEqual(openedContent, "hello", "openFile.content stays pinned at the opened value")
        XCTAssertEqual(c.liveBuffer(for: id), "hello12", "live buffer must survive the switch")

        // What a view would actually show on switch-back:
        let effectiveText = c.liveBuffer(for: id) ?? openedContent
        XCTAssertEqual(effectiveText, "hello12", "editor must show live content, not the stale opened content")
    }
}
