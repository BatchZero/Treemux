//
//  SFTPServiceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SFTPServiceTests: XCTestCase {
    func test_isConnected_initiallyFalse() async {
        let s = SFTPService()
        let connected = await s.isConnected
        XCTAssertFalse(connected)
    }

    // MARK: - parseListing: GNU `ls -lA --time-style=+%s`

    /// Linux GNU `ls -lA --time-style=+%s` emits exactly seven space-separated
    /// fields per file when the name has no embedded spaces:
    ///   perms  links  owner  group  size  epoch  name
    /// Regression for the empty-tree-on-remote-Linux bug: an off-by-one guard
    /// (`>= 8`) silently dropped every single-word filename.
    func test_parseListing_GNU_singleWordFilename_isParsed() {
        let output = """
        total 24
        -rw-r--r-- 1 user users 1234 1714000000 README.md
        """
        let entries = SFTPService.parseListing(output: output, parentPath: "/home/user/proj")

        XCTAssertEqual(entries.count, 1)
        let e = try! XCTUnwrap(entries.first)
        XCTAssertEqual(e.name, "README.md")
        XCTAssertEqual(e.path, "/home/user/proj/README.md")
        XCTAssertEqual(e.sizeBytes, 1234)
        XCTAssertEqual(e.kind, .file)
        XCTAssertEqual(e.modifiedAt, Date(timeIntervalSince1970: 1714000000))
    }

    func test_parseListing_GNU_mixedKinds_areParsed() {
        let output = """
        total 12
        drwxr-xr-x 2 alice alice  4096 1714000100 src
        -rw-r--r-- 1 alice alice    42 1714000200 hello.swift
        lrwxrwxrwx 1 alice alice    11 1714000300 link -> hello.swift
        """
        let entries = SFTPService.parseListing(output: output, parentPath: "/home/alice")

        XCTAssertEqual(entries.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["src"]?.kind, .directory)
        XCTAssertEqual(byName["hello.swift"]?.kind, .file)
        XCTAssertEqual(byName["link"]?.kind, .symlink(target: "hello.swift"))
    }

    func test_parseListing_GNU_filenameWithSpaces_keepsFullName() {
        let output = "-rw-r--r-- 1 u g 7 1714000000 My Notes.txt"
        let entries = SFTPService.parseListing(output: output, parentPath: "/srv")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "My Notes.txt")
        XCTAssertEqual(entries.first?.path, "/srv/My Notes.txt")
    }

    // MARK: - parseListing: BSD `ls -lAT`

    func test_parseListing_BSD_singleWordFilename_isParsed() {
        let output = "-rw-r--r--  1 user  staff  1234 Apr 30 12:34:56 2026 README.md"
        let entries = SFTPService.parseListing(output: output, parentPath: "/Users/user/proj")

        XCTAssertEqual(entries.count, 1)
        let e = try! XCTUnwrap(entries.first)
        XCTAssertEqual(e.name, "README.md")
        XCTAssertEqual(e.sizeBytes, 1234)
        XCTAssertEqual(e.kind, .file)
        XCTAssertNotNil(e.modifiedAt)
    }

    // MARK: - parseListing: edge cases

    func test_parseListing_emptyOutput_returnsEmpty() {
        XCTAssertTrue(SFTPService.parseListing(output: "", parentPath: "/").isEmpty)
    }

    func test_parseListing_skipsTotalAndDotEntries() {
        // `ls -A` already strips `.`/`..`, but parser also drops them defensively.
        let output = """
        total 0
        drwxr-xr-x 3 u g 96 1714000000 .
        drwxr-xr-x 6 u g 96 1714000000 ..
        -rw-r--r-- 1 u g 10 1714000000 keep
        """
        let entries = SFTPService.parseListing(output: output, parentPath: "/x")
        XCTAssertEqual(entries.map(\.name), ["keep"])
    }

    func test_parseListing_joinsParentPathTrailingSlash() {
        let output = "-rw-r--r-- 1 u g 1 1714000000 file"
        let withSlash = SFTPService.parseListing(output: output, parentPath: "/x/")
        let withoutSlash = SFTPService.parseListing(output: output, parentPath: "/x")
        XCTAssertEqual(withSlash.first?.path, "/x/file")
        XCTAssertEqual(withoutSlash.first?.path, "/x/file")
    }
}
