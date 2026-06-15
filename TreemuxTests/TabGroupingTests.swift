//
//  TabGroupingTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class TabGroupingTests: XCTestCase {

    private struct Item { let id: Int; let kind: WorkspaceTabKind }

    func testPartitionSplitsByKindPreservingOrder() {
        let items = [
            Item(id: 1, kind: .terminal),
            Item(id: 2, kind: .fileBrowser),
            Item(id: 3, kind: .terminal),
            Item(id: 4, kind: .fileBrowser),
        ]
        let groups = TabGrouping.partition(items) { $0.kind }
        XCTAssertEqual(groups.files.map(\.id), [2, 4])
        XCTAssertEqual(groups.shell.map(\.id), [1, 3])
    }

    func testPartitionEmpty() {
        let groups = TabGrouping.partition([Item]()) { $0.kind }
        XCTAssertTrue(groups.files.isEmpty)
        XCTAssertTrue(groups.shell.isEmpty)
    }

    func testPartitionAllOneKind() {
        let items = [Item(id: 1, kind: .fileBrowser), Item(id: 2, kind: .fileBrowser)]
        let groups = TabGrouping.partition(items) { $0.kind }
        XCTAssertEqual(groups.files.map(\.id), [1, 2])
        XCTAssertTrue(groups.shell.isEmpty)
    }

    func testPartitionAllShell() {
        let items = [Item(id: 1, kind: .terminal), Item(id: 2, kind: .terminal)]
        let groups = TabGrouping.partition(items) { $0.kind }
        XCTAssertEqual(groups.shell.map(\.id), [1, 2])
        XCTAssertTrue(groups.files.isEmpty)
    }
}
