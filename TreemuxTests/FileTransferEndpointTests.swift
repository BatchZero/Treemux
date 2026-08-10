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
        let temporaryURL = URL(fileURLWithPath: destinationURL.path + ".treemux-transfer-123.part")
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

    func testLocalTemporaryCreationIsExclusive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-transfer-exclusive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryURL = root.appendingPathComponent("existing.part")
        try Data("legitimate".utf8).write(to: temporaryURL)
        let endpoint = LocalFileTransferEndpoint()

        do {
            try await endpoint.createTemporaryFile(at: temporaryURL.path)
            XCTFail("Expected exclusive temporary-file creation to fail")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: temporaryURL), Data("legitimate".utf8))
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

    func testCitadelAtomicOverwriteFailureNeverMovesExistingDestination() async {
        actor FakeFiles {
            enum Failure: Error { case rename }
            var files: [String: Data] = [
                "/target/item": Data("old".utf8),
                "/target/temp": Data("new".utf8)
            ]

            func execute(_ command: String) throws {
                XCTAssertEqual(command, "mv -f -- '/target/temp' '/target/item'")
                throw Failure.rename
            }
            func data(at path: String) -> Data? { files[path] }
        }
        let files = FakeFiles()

        do {
            try await SFTPService.atomicallyReplaceCitadelItem(
                temporaryPath: "/target/temp",
                destinationPath: "/target/item",
                execute: { try await files.execute($0) }
            )
            XCTFail("Expected replacement failure")
        } catch {}

        let destination = await files.data(at: "/target/item")
        XCTAssertEqual(destination, Data("old".utf8))
    }

    func testSingleFlightSharesOneConcurrentReconnect() async throws {
        actor Counter {
            var calls = 0
            func increment() { calls += 1 }
        }
        let gate = AsyncSingleFlight()
        let counter = Counter()

        async let first: Void = gate.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
        }
        async let second: Void = gate.run {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await (first, second)

        let calls = await counter.calls
        XCTAssertEqual(calls, 1)
    }

    func testSystemSSHStatFailureDistinguishesMissingPathFromConnectionLoss() {
        let missing = SFTPService.transferStatFailure(exitCode: 44, path: "/missing")
        let disconnected = SFTPService.transferStatFailure(exitCode: 255, path: "/remote")
        let permissionDenied = SFTPService.transferStatFailure(exitCode: 1, path: "/private")

        guard case .notFound("/missing") = missing else {
            return XCTFail("Expected an explicit not-found error")
        }
        guard case .connectionLost = disconnected else {
            return XCTFail("Expected a retryable connection-loss error")
        }
        guard case .commandFailed = permissionDenied else {
            return XCTFail("Expected a non-missing stat failure to remain actionable")
        }
    }

    func testSystemSSHDirectoryCreationClassifiesConnectionLossAsRetryable() {
        let error = SFTPService.transferCommandFailure(
            exitCode: 255,
            detail: "mkdir failed at /target/folder"
        )
        guard case .connectionLost = error else {
            return XCTFail("Expected directory creation connection loss")
        }
    }

    func testResolvedFileSymlinkUsesTargetSizeForBothLongerAndShorterTargets() {
        let symlink = SFTPRichStat(
            path: "/remote/link", isDirectory: false, isSymlink: true,
            sizeBytes: 10, modifiedAt: nil
        )
        let longerTarget = SFTPRichStat(
            path: "/remote/link", isDirectory: false, isSymlink: false,
            sizeBytes: 24, modifiedAt: nil
        )
        let shorterTarget = SFTPRichStat(
            path: "/remote/link", isDirectory: false, isSymlink: false,
            sizeBytes: 3, modifiedAt: nil
        )

        let longer = RemoteFileBrowserDataSource.transferFileMetadata(
            stat: symlink,
            resolvedTargetStat: longerTarget
        )
        let shorter = RemoteFileBrowserDataSource.transferFileMetadata(
            stat: symlink,
            resolvedTargetStat: shorterTarget
        )

        XCTAssertEqual(longer.sizeBytes, 24)
        XCTAssertEqual(shorter.sizeBytes, 3)
        let command = SFTPService.transferStatCommand(
            path: "/remote/link",
            followSymbolicLinks: true
        )
        XCTAssertTrue(command.contains("stat -L -c"))
        XCTAssertTrue(command.contains("stat -L -f"))
    }
}
