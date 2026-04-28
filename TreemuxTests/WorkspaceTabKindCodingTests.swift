//
//  WorkspaceTabKindCodingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class WorkspaceTabKindCodingTests: XCTestCase {
    func testRoundTripTerminal() throws {
        let data = try JSONEncoder().encode(WorkspaceTabKind.terminal)
        let decoded = try JSONDecoder().decode(WorkspaceTabKind.self, from: data)
        XCTAssertEqual(decoded, .terminal)
    }

    func testRoundTripFileBrowser() throws {
        let data = try JSONEncoder().encode(WorkspaceTabKind.fileBrowser)
        let decoded = try JSONDecoder().decode(WorkspaceTabKind.self, from: data)
        XCTAssertEqual(decoded, .fileBrowser)
    }
}
