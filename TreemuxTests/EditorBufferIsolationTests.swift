//
//  EditorBufferIsolationTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

/// All-property counter for a FileBrowserTabController (see
/// ObservationChangeCounter in ObservableBridgeTests.swift).
@MainActor
private func makeCounter(for c: FileBrowserTabController) -> ObservationChangeCounter {
    ObservationChangeCounter {
        _ = c.rootPath; _ = c.rootKind; _ = c.splitRatio
        _ = c.expandedDirs; _ = c.showsHiddenFiles
        _ = c.rootChildren; _ = c.childrenByPath
        _ = c.subTabs; _ = c.activeSubTabID
        _ = c.loadingPaths; _ = c.loadError
        _ = c.diffHunksByPath; _ = c.fileStatusByPath
        _ = c.truncatedDirs; _ = c.treeContentGeneration
    }
}

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
        let counter = makeCounter(for: c)
        defer { counter.stop() }

        c.updateBuffer(content: "hello1", forSubTab: id)   // dirty flips: 1 publish
        let afterFirst = counter.count
        XCTAssertGreaterThan(afterFirst, 0)
        c.updateBuffer(content: "hello12", forSubTab: id)  // already dirty: no publish
        c.updateBuffer(content: "hello123", forSubTab: id)
        XCTAssertEqual(counter.count, afterFirst, "subsequent keystrokes must not publish")
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

    /// Regression for the save-window race: `saveCurrentFile` suspends on
    /// `await dataSource.writeFile`, and the user can keep typing during that
    /// suspension. The fix must compare the live buffer *after* the write
    /// completes against what was actually written, and only clear the buffer
    /// + dirty flag when they still match — otherwise a keystroke landed
    /// during the save gets silently discarded (buffer wiped, dirty cleared)
    /// even though it was never persisted.
    func testConcurrentKeystrokeDuringSaveIsNotDiscarded() async throws {
        let root = NSTemporaryDirectory() + "bufiso-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let filePath = root + "/a.txt"
        FileManager.default.createFile(atPath: filePath, contents: Data("hello".utf8))
        let ds = GatedWriteFileBrowserDataSource()
        let c = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: ds
        )
        await c.loadRoot()
        await c.openInTree(filePath)
        let id = try XCTUnwrap(c.activeSubTabID)

        c.updateBuffer(content: "v1", forSubTab: id)

        let saveTask = Task { @MainActor in try await c.saveCurrentFile() }
        await waitForPendingWrite(ds)
        // The user keeps typing while "v1" is in flight to disk.
        c.updateBuffer(content: "v2", forSubTab: id)
        ds.releaseWrite()
        try await saveTask.value

        XCTAssertEqual(
            c.liveBuffer(for: id), "v2",
            "keystrokes typed during the in-flight save must not be discarded")
        XCTAssertTrue(
            c.isDirty,
            "buffer diverged from what was actually saved, so dirty must stay true")
        let onDisk = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(onDisk, "v1", "the in-flight save persisted the pre-race content")
    }

    /// Regression for the save-completion race: `saveCurrentFile` captures
    /// `activeSubTabID` at the start (into `id`) and awaits `writeFile`, but
    /// the completion previously wrote the result back via
    /// `setActiveOpenFile`, which *re-reads* `activeSubTabID` rather than
    /// using the captured `id`. If the user switches the active sub-tab while
    /// the write is in flight, that re-read points at the new tab, so the
    /// save's result (dirty == false, saved content) lands on the wrong
    /// sub-tab instead of the one actually being saved — and the tab the
    /// user switched to gets silently overwritten with tab A's state.
    func testSaveCompletionAppliesToCapturedSubTabNotWhicheverIsActive() async throws {
        let root = NSTemporaryDirectory() + "bufiso-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let pathA = root + "/a.txt"
        let pathB = root + "/b.txt"
        FileManager.default.createFile(atPath: pathA, contents: Data("hello".utf8))
        FileManager.default.createFile(atPath: pathB, contents: Data("world".utf8))
        let ds = GatedWriteFileBrowserDataSource()
        let c = FileBrowserTabController(
            initial: FileBrowserTabState(rootPath: root, rootKind: .project),
            dataSource: ds
        )
        await c.loadRoot()

        // Open and pin tab A, then open and pin tab B, so both stay alive as
        // separate sub-tabs (an unpinned preview tab would be repurposed by
        // the second openInTree instead of creating a second tab).
        await c.openInTree(pathA)
        c.pinActiveSubTab()
        let idA = try XCTUnwrap(c.activeSubTabID)

        await c.openInTree(pathB)
        c.pinActiveSubTab()
        let idB = try XCTUnwrap(c.activeSubTabID)
        XCTAssertNotEqual(idA, idB)

        // Switch back to A, dirty it, and start saving it.
        c.activateSubTab(idA)
        XCTAssertEqual(c.activeSubTabID, idA)
        c.updateBuffer(content: "hello-edited", forSubTab: idA)

        let saveTask = Task { @MainActor in try await c.saveCurrentFile() }
        await waitForPendingWrite(ds)

        // While A's write is still in flight, the user switches to B.
        c.activateSubTab(idB)
        XCTAssertEqual(c.activeSubTabID, idB)

        ds.releaseWrite()
        try await saveTask.value

        // A must reflect the completed save, regardless of which tab is
        // active by the time the write finishes.
        let tabA = try XCTUnwrap(c.subTabs.first(where: { $0.id == idA }))
        guard case .text(let aPath, let aContent, _, let aDirty) = tabA.openFile else {
            XCTFail("expected tab A to still be .text")
            return
        }
        XCTAssertEqual(aPath, pathA)
        XCTAssertEqual(aContent, "hello-edited")
        XCTAssertFalse(aDirty, "tab A's save must clear dirty on tab A")
        XCTAssertEqual(
            try String(contentsOfFile: pathA, encoding: .utf8), "hello-edited")

        // B must be completely untouched by A's save completion.
        let tabB = try XCTUnwrap(c.subTabs.first(where: { $0.id == idB }))
        guard case .text(let bPath, let bContent, _, let bDirty) = tabB.openFile else {
            XCTFail("expected tab B to still be .text")
            return
        }
        XCTAssertEqual(bPath, pathB)
        XCTAssertEqual(bContent, "world")
        XCTAssertFalse(bDirty)
    }

    /// Regression for the data-loss UX bug: single-clicking a file in the tree
    /// opens a preview (unpinned) sub-tab; clicking a *different* file while
    /// that preview is dirty used to repurpose the same sub-tab in place
    /// (`openInTree`'s "reuse the preview" branch), silently discarding the
    /// unsaved edit and dropping its live buffer. VSCode semantics: editing a
    /// preview tab converts it to a regular (pinned) tab, so it's no longer a
    /// candidate for repurposing and a fresh preview opens for the new file
    /// instead — the edit survives.
    func testEditingPreviewTabAutoPinsAndSurvivesTreeNavigation() async throws {
        let (c, idA) = try await makeControllerWithOpenFile()
        // Freshly opened via openInTree: preview (unpinned) sub-tab.
        XCTAssertEqual(c.subTabs.count, 1)
        XCTAssertFalse(c.subTabs[0].isPinned)

        // Type into A: first divergence flips dirty AND must auto-pin.
        c.updateBuffer(content: "hello-edited", forSubTab: idA)
        let tabA = try XCTUnwrap(c.subTabs.first(where: { $0.id == idA }))
        XCTAssertTrue(tabA.isPinned, "editing a preview tab must convert it to pinned")
        guard case .text(_, _, _, let dirtyA) = tabA.openFile else {
            XCTFail("expected tab A to still be .text"); return
        }
        XCTAssertTrue(dirtyA)

        // Single-click a different file in the tree.
        let root = URL(fileURLWithPath: c.rootPath).path
        let pathB = root + "/b.txt"
        FileManager.default.createFile(atPath: pathB, contents: Data("b".utf8))
        await c.openInTree(pathB)

        // Must NOT have repurposed A's sub-tab: two sub-tabs now exist, A
        // intact with its live buffer, B a new preview.
        XCTAssertEqual(c.subTabs.count, 2, "editing A must not be discarded by opening B in place")
        let tabAAfter = try XCTUnwrap(c.subTabs.first(where: { $0.id == idA }))
        XCTAssertEqual(tabAAfter.path, root + "/a.txt")
        XCTAssertTrue(tabAAfter.isPinned)
        guard case .text(_, _, _, let dirtyAAfter) = tabAAfter.openFile else {
            XCTFail("expected tab A to still be .text"); return
        }
        XCTAssertTrue(dirtyAAfter, "A's dirty flag must survive opening B")
        XCTAssertEqual(c.liveBuffer(for: idA), "hello-edited", "A's live buffer must not be dropped")

        let idB = try XCTUnwrap(c.activeSubTabID)
        XCTAssertNotEqual(idB, idA)
        let tabB = try XCTUnwrap(c.subTabs.first(where: { $0.id == idB }))
        XCTAssertEqual(tabB.path, pathB)
        XCTAssertFalse(tabB.isPinned, "B opens as a fresh preview tab")

        // Single-click back on A: must hit the pinned-hit branch and focus
        // the existing (unsaved) tab rather than creating/repurposing again.
        await c.openInTree(root + "/a.txt")
        XCTAssertEqual(c.activeSubTabID, idA, "clicking A again must refocus its pinned tab")
        XCTAssertEqual(c.subTabs.count, 2, "no new sub-tab should be created")
        XCTAssertEqual(c.liveBuffer(for: idA), "hello-edited", "A's content must still be intact")
    }

    private func waitForPendingWrite(
        _ ds: GatedWriteFileBrowserDataSource,
        timeoutSeconds: Double = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while ds.pendingWriteCount() < 1 {
            if Date() > deadline {
                XCTFail("Timed out waiting for pending writeFile call")
                return
            }
            await Task.yield()
        }
    }
}

/// Test-only wrapper around `LocalFileBrowserDataSource` that suspends
/// `writeFile` on an explicit continuation until the test calls
/// `releaseWrite()`. Every other call is forwarded straight through to a real
/// local data source so the race test exercises an actual disk write, not an
/// in-memory stand-in.
final class GatedWriteFileBrowserDataSource: FileBrowserDataSource, @unchecked Sendable {
    private let inner = LocalFileBrowserDataSource()
    var supportsWrite: Bool { inner.supportsWrite }

    private let lock = NSLock()
    private var pendingWrites: [CheckedContinuation<Void, Never>] = []

    func pendingWriteCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pendingWrites.count
    }

    func releaseWrite() {
        lock.lock()
        let cont = pendingWrites.isEmpty ? nil : pendingWrites.removeFirst()
        lock.unlock()
        cont?.resume()
    }

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await inner.listDirectory(path)
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        try await inner.fileMetadata(path)
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await inner.readFile(path, maxBytes: maxBytes)
    }

    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data {
        try await inner.readPrefix(path, maxBytes: maxBytes)
    }

    func writeFile(_ path: String, data: Data) async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock(); pendingWrites.append(cont); lock.unlock()
        }
        try await inner.writeFile(path, data: data)
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await inner.downloadForQuickLook(path, progress: progress)
    }
}
