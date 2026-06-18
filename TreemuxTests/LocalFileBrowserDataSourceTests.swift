//
//  LocalFileBrowserDataSourceTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class LocalFileBrowserDataSourceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-fb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testListDirectoryReturnsFilesAndSubdirs() async throws {
        let sub = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        let ds = LocalFileBrowserDataSource()
        let nodes = try await ds.listDirectory(tmpDir.path)
        let names = Set(nodes.map(\.name))
        XCTAssertTrue(names.contains("sub"))
        XCTAssertTrue(names.contains("hello.txt"))

        let dirNode = nodes.first { $0.name == "sub" }
        XCTAssertEqual(dirNode?.kind, .directory)
        let fileNode = nodes.first { $0.name == "hello.txt" }
        XCTAssertEqual(fileNode?.kind, .file)
        XCTAssertEqual(fileNode?.sizeBytes, 2)
    }

    func testFileMetadata() async throws {
        let file = tmpDir.appendingPathComponent("a.bin")
        try Data(repeating: 0, count: 1024).write(to: file)
        let ds = LocalFileBrowserDataSource()
        let meta = try await ds.fileMetadata(file.path)
        XCTAssertEqual(meta.sizeBytes, 1024)
        XCTAssertFalse(meta.isDirectory)
    }

    func testReadFileSmall() async throws {
        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readFile(file.path, maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
    }

    func testReadFileTooLargeThrows() async throws {
        let file = tmpDir.appendingPathComponent("big.bin")
        try Data(repeating: 1, count: 5000).write(to: file)
        let ds = LocalFileBrowserDataSource()
        do {
            _ = try await ds.readFile(file.path, maxBytes: 1024)
            XCTFail("expected fileTooLarge")
        } catch FileBrowserError.fileTooLarge {
            // expected
        }
    }

    // readPrefix is the read variant used for content sniffing: it must never
    // throw fileTooLarge. It returns up to maxBytes from the start of the file.

    func testReadPrefixReturnsAllBytesForSmallFile() async throws {
        let file = tmpDir.appendingPathComponent("small.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readPrefix(file.path, maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi")
    }

    func testReadPrefixTruncatesLargeFileWithoutThrowing() async throws {
        let file = tmpDir.appendingPathComponent("big.txt")
        // 5000 bytes of 'A' — well over the 512-byte sniff window.
        try Data(repeating: 0x41, count: 5000).write(to: file)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readPrefix(file.path, maxBytes: 512)
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual(data.first, 0x41)
        XCTAssertEqual(data.last, 0x41)
    }

    func testReadPrefixOnEmptyFileReturnsEmpty() async throws {
        let file = tmpDir.appendingPathComponent("empty.txt")
        try Data().write(to: file)
        let ds = LocalFileBrowserDataSource()
        let data = try await ds.readPrefix(file.path, maxBytes: 512)
        XCTAssertEqual(data.count, 0)
    }

    func testWriteFileAtomic() async throws {
        let file = tmpDir.appendingPathComponent("out.txt")
        let ds = LocalFileBrowserDataSource()
        try await ds.writeFile(file.path, data: "alpha".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha")
        // Overwrite
        try await ds.writeFile(file.path, data: "beta".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "beta")
    }

    // MARK: - buildNodes (skip-unreadable robustness)

    private func fileNode(_ url: URL) -> FileNode {
        FileNode(id: url.path, name: url.lastPathComponent, path: url.path,
                 kind: .file, sizeBytes: nil, modifiedAt: nil)
    }

    private func dirNode(_ url: URL) -> FileNode {
        FileNode(id: url.path, name: url.lastPathComponent, path: url.path,
                 kind: .directory, sizeBytes: nil, modifiedAt: nil)
    }

    // Core of the bug fix: one entry whose node-build throws (e.g. the
    // TCC-protected ~/.Trash) must NOT abort the whole listing.
    func testBuildNodesSkipsEntriesThatThrow() {
        let parent = URL(fileURLWithPath: "/parent")
        let raw = ["a.txt", ".Trash", "b.txt"].map { parent.appendingPathComponent($0) }

        let nodes = LocalFileBrowserDataSource.buildNodes(from: raw, parent: parent) { url in
            if url.lastPathComponent == ".Trash" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return self.fileNode(url)
        }

        XCTAssertEqual(nodes.map(\.name), ["a.txt", "b.txt"])
    }

    func testBuildNodesSortsDirectoriesFirstThenAlpha() {
        let parent = URL(fileURLWithPath: "/parent")
        let raw = ["zebra.txt", "alpha", "beta.txt"].map { parent.appendingPathComponent($0) }

        let nodes = LocalFileBrowserDataSource.buildNodes(from: raw, parent: parent) { url in
            url.lastPathComponent == "alpha" ? self.dirNode(url) : self.fileNode(url)
        }

        XCTAssertEqual(nodes.map(\.name), ["alpha", "beta.txt", "zebra.txt"])
    }

    func testBuildNodesAllSucceedReturnsAll() {
        let parent = URL(fileURLWithPath: "/parent")
        let raw = ["one", "two"].map { parent.appendingPathComponent($0) }
        let nodes = LocalFileBrowserDataSource.buildNodes(from: raw, parent: parent) { self.fileNode($0) }
        XCTAssertEqual(Set(nodes.map(\.name)), Set(["one", "two"]))
    }
}
