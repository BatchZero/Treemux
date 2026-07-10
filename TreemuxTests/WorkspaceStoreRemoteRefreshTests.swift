//
//  WorkspaceStoreRemoteRefreshTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

/// Rendezvous barrier: every arriving task suspends until `expected` tasks
/// have arrived, then all resume together. Under serial execution the first
/// arrival would wait forever — `failSafe` unblocks stragglers after a
/// timeout and records the failure so the test fails instead of hanging.
private actor Rendezvous {
    private let expected: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var timedOut = false

    init(expected: Int) { self.expected = expected }

    func arrive() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
            if waiters.count == expected {
                for w in waiters { w.resume() }
                waiters.removeAll()
            }
        }
    }

    func failSafe(afterSeconds seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.releaseStragglers()
        }
    }

    private func releaseStragglers() {
        guard !waiters.isEmpty else { return }
        timedOut = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

private actor VisitLog {
    private(set) var values: [UUID] = []
    func record(_ id: UUID) { values.append(id) }
}

@MainActor
final class WorkspaceStoreRemoteRefreshTests: XCTestCase {
    private func clearState() throws {
        let dir = treemuxStateDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    override func setUp() async throws { try clearState() }
    override func tearDown() async throws { try clearState() }

    /// P2 acceptance: remote refreshes overlap. All three refresh closures must
    /// be in flight simultaneously — under the old serial for-loop the first
    /// one blocks the rest, the rendezvous times out, and the test fails.
    func test_refreshRemoteWorkspacesConcurrently_overlapsAllRefreshes() async {
        let store = WorkspaceStore()
        let ids = [UUID(), UUID(), UUID()]
        let rendezvous = Rendezvous(expected: ids.count)
        await rendezvous.failSafe(afterSeconds: 5)

        await store.refreshRemoteWorkspacesConcurrently(ids: ids) { _ in
            await rendezvous.arrive()
        }

        let timedOut = await rendezvous.timedOut
        XCTAssertFalse(timedOut, "refreshes ran serially — they must overlap")
    }

    /// Every id is visited exactly once, and the call returns only after all
    /// refreshes complete.
    func test_refreshRemoteWorkspacesConcurrently_visitsEveryIDOnce() async {
        let store = WorkspaceStore()
        let ids = (0..<5).map { _ in UUID() }
        let log = VisitLog()

        await store.refreshRemoteWorkspacesConcurrently(ids: ids) { id in
            await log.record(id)
        }

        let recorded = await log.values
        XCTAssertEqual(Set(recorded), Set(ids))
        XCTAssertEqual(recorded.count, ids.count)
    }
}
