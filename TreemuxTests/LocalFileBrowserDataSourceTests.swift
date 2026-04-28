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

    func testWriteFileAtomic() async throws {
        let file = tmpDir.appendingPathComponent("out.txt")
        let ds = LocalFileBrowserDataSource()
        try await ds.writeFile(file.path, data: "alpha".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha")
        // Overwrite
        try await ds.writeFile(file.path, data: "beta".data(using: .utf8)!)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "beta")
    }
}
