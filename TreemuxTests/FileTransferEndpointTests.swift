import XCTest
@testable import Treemux

final class FileTransferEndpointTests: XCTestCase {
    func testLocalEndpointReadsAndWritesAtOffsetsThenAtomicallyReplaces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-transfer-endpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let destinationURL = root.appendingPathComponent("destination.bin")
        let temporaryURL = URL(fileURLWithPath: destinationURL.path + FileTransferCoordinator.temporarySuffix)
        try Data([0, 1, 2, 3, 4, 5]).write(to: sourceURL)
        try Data([9]).write(to: destinationURL)
        let endpoint = LocalFileTransferEndpoint()

        let chunk = try await endpoint.readChunk(at: sourceURL.path, offset: 2, length: 3)
        try await endpoint.createTemporaryFile(at: temporaryURL.path)
        try await endpoint.writeChunk(Data([7, 8]), to: temporaryURL.path, offset: 0)
        try await endpoint.writeChunk(Data([9, 10]), to: temporaryURL.path, offset: 2)
        try await endpoint.replaceItem(at: destinationURL.path, withTemporaryItemAt: temporaryURL.path)

        XCTAssertEqual(chunk, Data([2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data([7, 8, 9, 10]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testLocalEndpointListsOnlyImmediateChildrenAndResolvesDirectoryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-transfer-children-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.txt"))
        try Data().write(to: nested.appendingPathComponent("nested.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = LocalFileTransferEndpoint()

        let children = try await endpoint.children(at: root.path)
        let metadata = try await endpoint.metadata(at: nested.path)

        XCTAssertEqual(children, [nested.path, root.appendingPathComponent("file.txt").path])
        XCTAssertEqual(metadata?.kind, .directory)
        XCTAssertEqual(metadata?.canonicalIdentity, nested.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testSSHChunkCommandsAreBoundedBinarySafeAndOffsetAware() {
        let read = SFTPService.transferReadCommand(path: "/tmp/a b", offset: 1024, length: 4096)
        let write = SFTPService.transferWriteCommand(path: "/tmp/a b", offset: 1024)
        let replace = SFTPService.transferReplaceCommand(temporaryPath: "/tmp/a.part", destinationPath: "/tmp/a")

        XCTAssertTrue(read.contains("dd if='/tmp/a b' bs=1 skip=1024 count=4096"))
        XCTAssertTrue(read.hasSuffix("| base64"))
        XCTAssertTrue(write.contains("base64 -d | dd of='/tmp/a b' bs=1 seek=1024 conv=notrunc"))
        XCTAssertEqual(replace, "mv -f -- '/tmp/a.part' '/tmp/a'")
    }
}
