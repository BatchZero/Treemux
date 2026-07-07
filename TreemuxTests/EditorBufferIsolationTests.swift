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
