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

    func testLocalEndpointUsesResolvedFileSizeForSymbolicLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-transfer-file-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("target.bin")
        let linkURL = root.appendingPathComponent("link.bin")
        let targetData = Data(repeating: 0xAB, count: 100)
        try targetData.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let endpoint = LocalFileTransferEndpoint()

        let metadata = try await endpoint.metadata(at: linkURL.path)
        let chunk = try await endpoint.readChunk(at: linkURL.path, offset: 0, length: targetData.count)

        XCTAssertEqual(metadata?.kind, .file)
        XCTAssertEqual(metadata?.sizeBytes, Int64(targetData.count))
        XCTAssertEqual(chunk, targetData)
    }

    func testSSHChunkCommandsUseEfficientBlocksAndPreserveExactOffsets() {
        let read = SFTPService.transferReadCommand(path: "/tmp/a b", offset: 262_144, length: 4096)
        let write = SFTPService.transferWriteCommand(path: "/tmp/a b", offset: 262_144)
        let replace = SFTPService.transferReplaceCommand(temporaryPath: "/tmp/a.part", destinationPath: "/tmp/a")

        XCTAssertTrue(read.contains("dd if='/tmp/a b' bs=65536 skip=4 count=1"))
        XCTAssertTrue(read.contains("| head -c 4096 | base64"))
        XCTAssertFalse(read.contains("bs=1 "))
        XCTAssertTrue(read.hasSuffix("| base64"))
        XCTAssertTrue(write.contains("base64 -d | dd of='/tmp/a b' bs=65536 seek=4 conv=notrunc"))
        XCTAssertFalse(write.contains("bs=1 "))
        XCTAssertEqual(replace, "mv -f -- '/tmp/a.part' '/tmp/a'")
    }

    func testSSHChunkCommandsAvoidByteBlocksForUnalignedOffsets() {
        let read = SFTPService.transferReadCommand(path: "/tmp/data", offset: 1025, length: 4096)
        let write = SFTPService.transferWriteCommand(path: "/tmp/data", offset: 1025)

        XCTAssertTrue(read.contains("dd if='/tmp/data' bs=65536 skip=0 count=1"))
        XCTAssertTrue(read.contains("| tail -c +1026 | head -c 4096 | base64"))
        XCTAssertFalse(read.contains("bs=1 "))
        XCTAssertTrue(write.contains("dd if='/tmp/data' bs=65536 skip=0 count=1"))
        XCTAssertTrue(write.contains("| head -c 1025; base64 -d;"))
        XCTAssertTrue(write.contains("dd of='/tmp/data' bs=65536 seek=0 conv=notrunc"))
        XCTAssertFalse(write.contains("bs=1 "))
    }

    func testSSHChunkCommandsReadAndWriteUnalignedOffsets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("treemux-transfer-shell-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("data.bin")
        let original = Data((0..<100_000).map { UInt8($0 % 251) })
        try original.write(to: fileURL)

        let readCommand = SFTPService.transferReadCommand(
            path: fileURL.path,
            offset: 1025,
            length: 4096
        )
        let encodedChunk = try runShell(readCommand)
        let cleanedChunk = encodedChunk.filter { !$0.isWhitespace }
        let chunk = try XCTUnwrap(Data(base64Encoded: cleanedChunk))
        XCTAssertEqual(chunk, original.subdata(in: 1025..<(1025 + 4096)))

        let replacement = Data(repeating: 0xEE, count: 4096)
        let writeCommand = SFTPService.transferWriteCommand(path: fileURL.path, offset: 1025)
        _ = try runShell(writeCommand, stdin: replacement.base64EncodedData())
        let written = try Data(contentsOf: fileURL)
        XCTAssertEqual(written.prefix(1025), original.prefix(1025))
        XCTAssertEqual(written.subdata(in: 1025..<(1025 + replacement.count)), replacement)
        XCTAssertEqual(
            written.suffix(from: 1025 + replacement.count),
            original.suffix(from: 1025 + replacement.count)
        )
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

    private func runShell(_ command: String, stdin: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        if stdin != nil {
            process.standardInput = input
        }
        try process.run()
        if let stdin {
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return String(decoding: data, as: UTF8.self)
    }
}
