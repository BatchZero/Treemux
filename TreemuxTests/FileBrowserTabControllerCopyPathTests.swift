//
//  FileBrowserTabControllerCopyPathTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

@MainActor
final class FileBrowserTabControllerCopyPathTests: XCTestCase {
    func test_relativePath_stripsRootPrefix() {
        let ctrl = makeController(rootPath: "/Users/x/repo")
        XCTAssertEqual(ctrl.relativePath("/Users/x/repo/Sources/Foo.swift"), "Sources/Foo.swift")
    }

    func test_relativePath_returnsAbsoluteIfOutsideRoot() {
        let ctrl = makeController(rootPath: "/Users/x/repo")
        XCTAssertEqual(ctrl.relativePath("/etc/passwd"), "/etc/passwd")
    }

    func test_relativePath_handlesTrailingSlashRoot() {
        let ctrl = makeController(rootPath: "/Users/x/repo/")
        XCTAssertEqual(ctrl.relativePath("/Users/x/repo/a.txt"), "a.txt")
    }

    private func makeController(rootPath: String) -> FileBrowserTabController {
        FileBrowserTabController(
            initial: .init(rootPath: rootPath, rootKind: .project),
            dataSource: MockFileBrowserDataSource())
    }
}
