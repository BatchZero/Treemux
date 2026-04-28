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
}
