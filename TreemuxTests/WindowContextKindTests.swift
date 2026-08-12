//
//  WindowContextKindTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class WindowContextKindTests: XCTestCase {
    @MainActor
    func testMainKindPersists() {
        let store = WorkspaceStore()
        let ctx = WindowContext(store: store, kind: .main)
        if case .main = ctx.kind {} else { XCTFail("expected .main") }
    }

    @MainActor
    func testDetachedKindPersists() {
        let store = WorkspaceStore()
        let ref = DetachedNodeRef.workspace(UUID())
        let ctx = WindowContext(store: store, kind: .detached(ref))
        guard case .detached(let stored) = ctx.kind else {
            return XCTFail("expected .detached")
        }
        XCTAssertEqual(stored, ref)
    }
}
