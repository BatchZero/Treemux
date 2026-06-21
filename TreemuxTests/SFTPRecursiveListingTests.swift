//
//  SFTPRecursiveListingTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class SFTPRecursiveListingTests: XCTestCase {
    func test_bulkListCommand_hasMindepthMaxdepthAndBsdFallback() {
        let cmd = SFTPService.bulkListCommand(maxDepth: 2)
        XCTAssertTrue(cmd.contains("-mindepth 1"))
        XCTAssertTrue(cmd.contains("-maxdepth 2"))
        XCTAssertTrue(cmd.contains("--time-style=+%s"))
        XCTAssertTrue(cmd.contains("ls -ldnT"))
        XCTAssertTrue(cmd.contains("||"))
    }

    func test_bulkListCommand_appliesServerSideEntryCap() {
        let cmd = SFTPService.bulkListCommand(maxDepth: 2, maxEntries: 1234)
        // The whole GNU||BSD listing must be bounded, so it is wrapped and piped
        // through `head` — the safety valve that stops a huge remote tree from
        // streaming unbounded output back to the client (which spun forever).
        XCTAssertTrue(cmd.contains("head -n 1234"), "expected server-side line cap, got: \(cmd)")
        XCTAssertTrue(cmd.contains("||"), "both GNU and BSD branches must remain")
    }

    func test_bulkListCommand_defaultCapMatchesConstant() {
        let cmd = SFTPService.bulkListCommand(maxDepth: 2)
        XCTAssertTrue(cmd.contains("head -n \(SFTPService.bulkListMaxEntries)"))
    }

    func test_parseRecursive_GNU_nestedPaths_groupedByParent() {
        let output = """
        drwxr-xr-x 2 0 0 4096 1714000000 ./src
        -rw-r--r-- 1 0 0 12 1714000001 ./README.md
        -rw-r--r-- 1 0 0 34 1714000002 ./src/main.swift
        """
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/home/me/proj")
        XCTAssertEqual(grouped["/home/me/proj"]?.map(\.name), ["src", "README.md"])
        XCTAssertEqual(grouped["/home/me/proj/src"]?.map(\.name), ["main.swift"])
        let readme = grouped["/home/me/proj"]?.first(where: { $0.name == "README.md" })
        XCTAssertEqual(readme?.path, "/home/me/proj/README.md")
        XCTAssertEqual(readme?.sizeBytes, 12)
        XCTAssertEqual(readme?.modifiedAt, Date(timeIntervalSince1970: 1714000001))
        if case .file = readme?.kind {} else { XCTFail("expected file kind") }
    }

    func test_parseRecursive_symlink_capturesTarget() {
        let output = "lrwxr-xr-x 1 0 0 7 1714000000 ./link -> ../dest"
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/r")
        let link = grouped["/r"]?.first
        XCTAssertEqual(link?.name, "link")
        XCTAssertEqual(link?.path, "/r/link")
        if case .symlink(let target) = link?.kind {
            XCTAssertEqual(target, "../dest")
        } else {
            XCTFail("expected symlink kind")
        }
    }

    func test_parseRecursive_BSD_fourFieldDate() {
        let output = "-rw-r--r-- 1 0 0 5 Apr 24 12:00:00 2024 ./a.txt"
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/r")
        XCTAssertEqual(grouped["/r"]?.first?.name, "a.txt")
        XCTAssertEqual(grouped["/r"]?.first?.path, "/r/a.txt")
        XCTAssertEqual(grouped["/r"]?.first?.sizeBytes, 5)
    }

    func test_parseRecursive_nameWithSpaces_GNU() {
        let output = "-rw-r--r-- 1 0 0 5 1714000000 ./my file.txt"
        let grouped = SFTPService.parseRecursiveListing(output: output, root: "/r")
        XCTAssertEqual(grouped["/r"]?.first?.name, "my file.txt")
        XCTAssertEqual(grouped["/r"]?.first?.path, "/r/my file.txt")
    }
}
