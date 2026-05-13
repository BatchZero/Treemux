//
//  FileBrowserTabControllerStaleLoadTests.swift
//  TreemuxTests
//
//  Regression coverage for the race where an in-flight async load can
//  overwrite the wrong sub-tab's `openFile` because writes are routed by
//  current `activeSubTabID` rather than the sub-tab the load was issued
//  against. See FileBrowserTabController.setActiveOpenFile.
//

import Foundation
import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerStaleLoadTests: XCTestCase {
    func test_concurrentPinFile_keepsContentAlignedWithSubTab() async {
        let ds = GatedFileBrowserDataSource()
        ds.setContent("/r/a.txt", Data("AAA".utf8))
        ds.setContent("/r/b.txt", Data("BBB".utf8))
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: ds)

        let taskA = Task { @MainActor in await ctrl.pinFile("/r/a.txt") }
        await waitForPending(ds, count: 1)
        let taskB = Task { @MainActor in await ctrl.pinFile("/r/b.txt") }
        await waitForPending(ds, count: 2)

        // Resume out-of-order: B (current active) finishes first, then the
        // older A. Under the bug, A's late completion writes "AAA" into
        // sub-tab B because setActiveOpenFile blindly targets activeSubTabID.
        ds.release(path: "/r/b.txt")
        ds.release(path: "/r/a.txt")
        _ = await taskA.value
        _ = await taskB.value

        XCTAssertEqual(ctrl.subTabs.count, 2)
        let tabA = ctrl.subTabs.first(where: { $0.path == "/r/a.txt" })
        let tabB = ctrl.subTabs.first(where: { $0.path == "/r/b.txt" })
        XCTAssertEqual(
            tabA?.openFile,
            .text(path: "/r/a.txt", content: "AAA", encoding: .utf8, dirty: false),
            "Sub-tab /r/a.txt should display its own content")
        XCTAssertEqual(
            tabB?.openFile,
            .text(path: "/r/b.txt", content: "BBB", encoding: .utf8, dirty: false),
            "Sub-tab /r/b.txt must not be overwritten by /r/a.txt's late load")
    }

    func test_previewReuse_oldLoadCannotOverwriteNewPath() async {
        let ds = GatedFileBrowserDataSource()
        ds.setContent("/r/a.txt", Data("AAA".utf8))
        ds.setContent("/r/b.txt", Data("BBB".utf8))
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: ds)

        let taskA = Task { @MainActor in await ctrl.openInTree("/r/a.txt") }
        await waitForPending(ds, count: 1)
        // Reuses the same preview tab and changes its path to /r/b.txt while
        // /r/a.txt's read is still pending.
        let taskB = Task { @MainActor in await ctrl.openInTree("/r/b.txt") }
        await waitForPending(ds, count: 2)

        ds.release(path: "/r/b.txt")
        ds.release(path: "/r/a.txt")
        _ = await taskA.value
        _ = await taskB.value

        XCTAssertEqual(ctrl.subTabs.count, 1)
        XCTAssertEqual(ctrl.subTabs[0].path, "/r/b.txt")
        XCTAssertEqual(
            ctrl.subTabs[0].openFile,
            .text(path: "/r/b.txt", content: "BBB", encoding: .utf8, dirty: false),
            "Preview tab repurposed to /r/b.txt must not show /r/a.txt content")
    }

    func test_loadFromClosedSubTab_isDropped() async {
        let ds = GatedFileBrowserDataSource()
        ds.setContent("/r/a.txt", Data("AAA".utf8))
        ds.setContent("/r/b.txt", Data("BBB".utf8))
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: ds)

        let taskA = Task { @MainActor in await ctrl.pinFile("/r/a.txt") }
        await waitForPending(ds, count: 1)
        let taskB = Task { @MainActor in await ctrl.pinFile("/r/b.txt") }
        await waitForPending(ds, count: 2)

        // Close A's sub-tab while its read is still pending. Resume B first
        // (correct content lands in B) then A — A's late write must be
        // dropped, otherwise it overwrites B's content because activeSubTabID
        // still points at B.
        let aID = ctrl.subTabs.first(where: { $0.path == "/r/a.txt" })!.id
        ctrl.closeSubTabImmediate(aID)
        ds.release(path: "/r/b.txt")
        ds.release(path: "/r/a.txt")
        _ = await taskA.value
        _ = await taskB.value

        XCTAssertEqual(ctrl.subTabs.count, 1)
        XCTAssertEqual(ctrl.subTabs[0].path, "/r/b.txt")
        XCTAssertEqual(
            ctrl.subTabs[0].openFile,
            .text(path: "/r/b.txt", content: "BBB", encoding: .utf8, dirty: false))
    }

    func test_updateBuffer_routesByID_neverCrossesSubTabs() async {
        let ds = GatedFileBrowserDataSource()
        ds.setContent("/r/a.txt", Data("AAA".utf8))
        ds.setContent("/r/b.txt", Data("BBB".utf8))
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: ds)

        let taskA = Task { @MainActor in await ctrl.pinFile("/r/a.txt") }
        await waitForPending(ds, count: 1)
        ds.release(path: "/r/a.txt")
        _ = await taskA.value

        let taskB = Task { @MainActor in await ctrl.pinFile("/r/b.txt") }
        await waitForPending(ds, count: 1)
        ds.release(path: "/r/b.txt")
        _ = await taskB.value

        let aID = ctrl.subTabs.first(where: { $0.path == "/r/a.txt" })!.id
        let bID = ctrl.subTabs.first(where: { $0.path == "/r/b.txt" })!.id

        // Active is B (pinFile activates), but we're editing A explicitly.
        XCTAssertEqual(ctrl.activeSubTabID, bID)
        ctrl.updateBuffer(content: "AAA-edited", forSubTab: aID)

        let tabA = ctrl.subTabs.first(where: { $0.id == aID })
        let tabB = ctrl.subTabs.first(where: { $0.id == bID })
        XCTAssertEqual(
            tabA?.openFile,
            .text(path: "/r/a.txt", content: "AAA-edited", encoding: .utf8, dirty: true),
            "updateBuffer with aID must edit A")
        XCTAssertEqual(
            tabB?.openFile,
            .text(path: "/r/b.txt", content: "BBB", encoding: .utf8, dirty: false),
            "B must not be touched when we explicitly target A")
    }

    func test_updateBuffer_droppedIfSubTabClosed() async {
        let ds = GatedFileBrowserDataSource()
        ds.setContent("/r/a.txt", Data("AAA".utf8))
        let ctrl = FileBrowserTabController(
            initial: .init(rootPath: "/r", rootKind: .project),
            dataSource: ds)

        let taskA = Task { @MainActor in await ctrl.pinFile("/r/a.txt") }
        await waitForPending(ds, count: 1)
        ds.release(path: "/r/a.txt")
        _ = await taskA.value

        let aID = ctrl.subTabs[0].id
        ctrl.closeSubTabImmediate(aID)
        // A delayed binding setter that fires after close must not crash and
        // must not resurrect the sub-tab.
        ctrl.updateBuffer(content: "stale", forSubTab: aID)
        XCTAssertTrue(ctrl.subTabs.isEmpty)
    }

    // MARK: - Helpers

    private func waitForPending(
        _ ds: GatedFileBrowserDataSource,
        count: Int,
        timeoutSeconds: Double = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while ds.pendingCount() < count {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(count) pending readFile calls (have \(ds.pendingCount()))")
                return
            }
            await Task.yield()
        }
    }
}

/// Test data source whose `readFile` blocks on a per-call continuation until
/// the test explicitly calls `release(path:)`. Lets the test interleave two
/// concurrent loads deterministically.
final class GatedFileBrowserDataSource: FileBrowserDataSource, @unchecked Sendable {
    let supportsWrite: Bool = true

    private let lock = NSLock()
    private var fileContents: [String: Data] = [:]
    private var pending: [(path: String, cont: CheckedContinuation<Void, Never>)] = []

    func setContent(_ path: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        fileContents[path] = data
    }

    func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func release(path: String) {
        lock.lock()
        let cont: CheckedContinuation<Void, Never>?
        if let idx = pending.firstIndex(where: { $0.path == path }) {
            cont = pending.remove(at: idx).cont
        } else {
            cont = nil
        }
        lock.unlock()
        cont?.resume()
    }

    func listDirectory(_ path: String) async throws -> [FileNode] { [] }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        lock.lock()
        let size = Int64(fileContents[path]?.count ?? 0)
        lock.unlock()
        return FileMetadata(
            path: path, sizeBytes: size, modifiedAt: nil,
            isDirectory: false, isSymbolicLink: false)
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            pending.append((path, cont))
            lock.unlock()
        }
        lock.lock(); let data = fileContents[path] ?? Data(); lock.unlock()
        return data
    }

    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return fileContents[path]?.prefix(maxBytes) ?? Data()
    }

    func writeFile(_ path: String, data: Data) async throws {
        lock.lock(); fileContents[path] = data; lock.unlock()
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        URL(fileURLWithPath: path)
    }
}
