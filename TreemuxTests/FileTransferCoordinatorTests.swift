import XCTest
@testable import Treemux

@MainActor
final class FileTransferCoordinatorTests: XCTestCase {
    func testNestedFolderCopiesFilesAndEmptyDirectory() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/project": .directory(identity: "/source/project"),
            "/source/project/readme.txt": .file(Data("hello".utf8)),
            "/source/project/empty": .directory(identity: "/source/project/empty")
        ])
        let destination = MemoryTransferEndpoint(nodes: [
            "/downloads": .directory(identity: "/downloads")
        ])
        let coordinator = FileTransferCoordinator(
            source: source,
            destination: destination,
            chunkSize: 2,
            concurrencyLimit: 2
        )

        let summary = await coordinator.start(
            direction: .download,
            sources: ["/source/project"],
            destinationRoot: "/downloads"
        )

        XCTAssertEqual(summary.completedItems, 3)
        XCTAssertEqual(summary.failedItems, 0)
        let copiedData = await destination.fileData(at: "/downloads/project/readme.txt")
        let emptyKind = await destination.kind(at: "/downloads/project/empty")
        XCTAssertEqual(copiedData, Data("hello".utf8))
        XCTAssertEqual(emptyKind, .directory)
    }

    func testLargeFileUsesMultipleChunksAndAggregatesProgress() async {
        let payload = Data((0..<17).map(UInt8.init))
        let source = MemoryTransferEndpoint(nodes: ["/source/big.bin": .file(payload)])
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        let coordinator = FileTransferCoordinator(
            source: source,
            destination: destination,
            chunkSize: 4,
            concurrencyLimit: 1
        )

        let summary = await coordinator.start(
            direction: .upload,
            sources: ["/source/big.bin"],
            destinationRoot: "/target"
        )

        let readCount = await source.readCount
        let copiedData = await destination.fileData(at: "/target/big.bin")
        XCTAssertEqual(readCount, 5)
        XCTAssertEqual(summary.completedBytes, 17)
        XCTAssertEqual(summary.totalBytes, 17)
        XCTAssertEqual(copiedData, payload)
    }

    func testTransfersFilesConcurrentlyWithoutExceedingConfiguredLimit() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/folder": .directory(identity: "/source/folder"),
            "/source/folder/first.txt": .file(Data("first".utf8)),
            "/source/folder/second.txt": .file(Data("second".utf8)),
            "/source/folder/third.txt": .file(Data("third".utf8))
        ])
        await source.delayEachRead(by: .milliseconds(50))
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        let coordinator = FileTransferCoordinator(
            source: source,
            destination: destination,
            chunkSize: 64,
            concurrencyLimit: 2
        )

        let summary = await coordinator.start(
            direction: .upload,
            sources: ["/source/folder"],
            destinationRoot: "/target"
        )

        let maximumConcurrentReads = await source.maximumConcurrentReads
        XCTAssertEqual(summary.completedItems, 4)
        XCTAssertEqual(maximumConcurrentReads, 2)
    }

    func testConflictWaitsForOverwriteDecision() async {
        let source = MemoryTransferEndpoint(nodes: ["/source/a.txt": .file(Data("new".utf8))])
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target"),
            "/target/a.txt": .file(Data("old".utf8))
        ])
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .download,
                sources: ["/source/a.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.pendingConflict != nil }
        XCTAssertEqual(coordinator.state, .waitingForConflict)

        coordinator.resolveConflict(.overwrite)
        let summary = await task.value

        XCTAssertEqual(summary.completedItems, 1)
        let copiedData = await destination.fileData(at: "/target/a.txt")
        XCTAssertEqual(copiedData, Data("new".utf8))
    }

    func testSkipConflictLeavesDestinationAndContinuesSibling() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/a.txt": .file(Data("new".utf8)),
            "/source/b.txt": .file(Data("sibling".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target"),
            "/target/a.txt": .file(Data("old".utf8))
        ])
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .download,
                sources: ["/source/a.txt", "/source/b.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.pendingConflict != nil }
        coordinator.resolveConflict(.skip)
        let summary = await task.value

        XCTAssertEqual(summary.skippedItems, 1)
        XCTAssertEqual(summary.completedItems, 1)
        let preservedData = await destination.fileData(at: "/target/a.txt")
        let siblingData = await destination.fileData(at: "/target/b.txt")
        XCTAssertEqual(preservedData, Data("old".utf8))
        XCTAssertEqual(siblingData, Data("sibling".utf8))
    }

    func testCancelAllDuringConflictPreservesCompletedItems() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/done.txt": .file(Data("done".utf8)),
            "/source/conflict.txt": .file(Data("new".utf8)),
            "/source/queued.txt": .file(Data("queued".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target"),
            "/target/conflict.txt": .file(Data("old".utf8))
        ])
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .download,
                sources: ["/source/done.txt", "/source/conflict.txt", "/source/queued.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.pendingConflict != nil }
        coordinator.resolveConflict(.cancelAll)
        let summary = await task.value

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.cancelledItems, 2)
        let completedData = await destination.fileData(at: "/target/done.txt")
        let queuedData = await destination.fileData(at: "/target/queued.txt")
        let hasTemporaryItems = await destination.containsTemporaryItems
        XCTAssertEqual(completedData, Data("done".utf8))
        XCTAssertNil(queuedData)
        XCTAssertFalse(hasTemporaryItems)
    }

    func testCancellationAfterFinalChunkRemovesTemporaryFileInsteadOfReplacingDestination() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/item.txt": .file(Data("contents".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target")
        ])
        await destination.suspendNextWrite()
        let coordinator = FileTransferCoordinator(
            source: source,
            destination: destination,
            chunkSize: 64
        )

        let task = Task {
            await coordinator.start(
                direction: .download,
                sources: ["/source/item.txt"],
                destinationRoot: "/target"
            )
        }
        await destination.waitForSuspendedWrite()
        coordinator.cancel()
        await destination.resumeSuspendedWrite()
        let summary = await task.value
        let destinationData = await destination.fileData(at: "/target/item.txt")
        let hasTemporaryItems = await destination.containsTemporaryItems

        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(summary.completedItems, 0)
        XCTAssertNil(destinationData)
        XCTAssertFalse(hasTemporaryItems)
    }

    func testCancelledTransferRetriesCleanupAfterLostResponse() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/item.txt": .file(Data("contents".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target")
        ])
        await destination.suspendNextWrite()
        await destination.commitNextTemporaryRemovalThenLoseConnection()
        let coordinator = FileTransferCoordinator(
            source: source,
            destination: destination,
            chunkSize: 64
        )

        let task = Task {
            await coordinator.start(
                direction: .download,
                sources: ["/source/item.txt"],
                destinationRoot: "/target"
            )
        }
        await destination.waitForSuspendedWrite()
        coordinator.cancel()
        await destination.resumeSuspendedWrite()
        await waitUntil { coordinator.state == .paused }

        coordinator.retry()
        let summary = await task.value

        XCTAssertTrue(summary.cancelled)
        XCTAssertFalse(summary.failures.contains { $0.kind == .cleanup })
        let hasTemporaryItems = await destination.containsTemporaryItems
        XCTAssertFalse(hasTemporaryItems)
    }

    func testSiblingFailureDoesNotAbortBatch() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/bad.txt": .file(Data("bad".utf8)),
            "/source/good.txt": .file(Data("good".utf8))
        ])
        await source.failReads(at: "/source/bad.txt")
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let summary = await coordinator.start(
            direction: .upload,
            sources: ["/source/bad.txt", "/source/good.txt"],
            destinationRoot: "/target"
        )

        XCTAssertEqual(summary.failedItems, 1)
        XCTAssertEqual(summary.completedItems, 1)
        let copiedData = await destination.fileData(at: "/target/good.txt")
        let hasTemporaryItems = await destination.containsTemporaryItems
        XCTAssertEqual(summary.failures.map { $0.sourcePath }, ["/source/bad.txt"])
        XCTAssertEqual(copiedData, Data("good".utf8))
        XCTAssertFalse(hasTemporaryItems)
    }

    func testRetryableFailurePausesNewWorkUntilRetry() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/a.txt": .file(Data("a".utf8)),
            "/source/b.txt": .file(Data("b".utf8))
        ])
        await source.failNextReadRetryably(at: "/source/a.txt")
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        let coordinator = FileTransferCoordinator(
            source: source,
            destination: destination,
            concurrencyLimit: 1
        )

        let task = Task {
            await coordinator.start(
                direction: .upload,
                sources: ["/source/a.txt", "/source/b.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.state == .paused }

        XCTAssertNotNil(coordinator.pendingRetryableError)
        let siblingBeforeRetry = await destination.fileData(at: "/target/b.txt")
        XCTAssertNil(siblingBeforeRetry)

        coordinator.retry()
        let summary = await task.value

        XCTAssertEqual(summary.completedItems, 2)
        XCTAssertEqual(summary.failedItems, 0)
        let first = await destination.fileData(at: "/target/a.txt")
        let second = await destination.fileData(at: "/target/b.txt")
        XCTAssertEqual(first, Data("a".utf8))
        XCTAssertEqual(second, Data("b".utf8))
    }

    func testCommittedTemporaryCreationIsRecoveredAfterLostResponse() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/item.txt": .file(Data("new".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        await destination.commitNextTemporaryCreationThenLoseConnection()
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .upload,
                sources: ["/source/item.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.state == .paused }
        coordinator.retry()
        let summary = await task.value

        XCTAssertEqual(summary.completedItems, 1)
        XCTAssertEqual(summary.failedItems, 0)
        let copied = await destination.fileData(at: "/target/item.txt")
        XCTAssertEqual(copied, Data("new".utf8))
    }

    func testCommittedReplacementIsRecoveredAfterLostResponse() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/item.txt": .file(Data("new".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        await destination.commitNextReplacementThenLoseConnection()
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .upload,
                sources: ["/source/item.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.state == .paused }
        coordinator.retry()
        let summary = await task.value

        XCTAssertEqual(summary.completedItems, 1)
        XCTAssertEqual(summary.failedItems, 0)
        let copied = await destination.fileData(at: "/target/item.txt")
        XCTAssertEqual(copied, Data("new".utf8))
    }

    func testCommittedRemovalIsRecoveredAfterLostResponse() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/item": .file(Data("new".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target"),
            "/target/item": .directory(identity: "/target/item")
        ])
        await destination.commitNextRemovalThenLoseConnection(at: "/target/item")
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .upload,
                sources: ["/source/item"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.state == .waitingForConflict }
        coordinator.resolveConflict(.overwrite)
        await waitUntil { coordinator.state == .paused }
        coordinator.retry()
        let summary = await task.value

        XCTAssertEqual(summary.completedItems, 1)
        XCTAssertEqual(summary.failedItems, 0)
        let copied = await destination.fileData(at: "/target/item")
        XCTAssertEqual(copied, Data("new".utf8))
    }

    func testTemporaryCleanupFailureIsReported() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/bad.txt": .file(Data("bad".utf8))
        ])
        await source.failReads(at: "/source/bad.txt")
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        await destination.failTemporaryRemovals()
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let summary = await coordinator.start(
            direction: .upload,
            sources: ["/source/bad.txt"],
            destinationRoot: "/target"
        )

        XCTAssertEqual(summary.failedItems, 1)
        XCTAssertEqual(summary.failures.map(\.kind), [.cleanup, .operation])
    }

    func testCommittedTemporaryCleanupIsRecoveredAfterLostResponse() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/bad.txt": .file(Data("bad".utf8))
        ])
        await source.failReads(at: "/source/bad.txt")
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        await destination.commitNextTemporaryRemovalThenLoseConnection()
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let task = Task {
            await coordinator.start(
                direction: .upload,
                sources: ["/source/bad.txt"],
                destinationRoot: "/target"
            )
        }
        await waitUntil { coordinator.state == .paused }

        coordinator.retry()
        let summary = await task.value

        XCTAssertEqual(summary.failedItems, 1)
        XCTAssertEqual(summary.failures.map(\.kind), [.operation])
        let hasTemporaryItems = await destination.containsTemporaryItems
        XCTAssertFalse(hasTemporaryItems)
    }

    func testLegacyTemporarySuffixFileIsNeverTouched() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/item.txt": .file(Data("new".utf8))
        ])
        let legacyPath = "/target/item.txt.treemux-transfer-part"
        let destination = MemoryTransferEndpoint(nodes: [
            "/target": .directory(identity: "/target"),
            legacyPath: .file(Data("legitimate".utf8))
        ])
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let summary = await coordinator.start(
            direction: .upload,
            sources: ["/source/item.txt"],
            destinationRoot: "/target"
        )

        XCTAssertEqual(summary.completedItems, 1)
        let preserved = await destination.fileData(at: legacyPath)
        XCTAssertEqual(preserved, Data("legitimate".utf8))
    }

    func testSymlinkCycleIsReportedWithoutAbortingSibling() async {
        let source = MemoryTransferEndpoint(nodes: [
            "/source/folder": .directory(identity: "/canonical/folder"),
            "/source/folder/loop": .directory(identity: "/canonical/folder"),
            "/source/folder/ok.txt": .file(Data("ok".utf8))
        ])
        let destination = MemoryTransferEndpoint(nodes: ["/target": .directory(identity: "/target")])
        let coordinator = FileTransferCoordinator(source: source, destination: destination)

        let summary = await coordinator.start(
            direction: .download,
            sources: ["/source/folder"],
            destinationRoot: "/target"
        )

        XCTAssertEqual(summary.failedItems, 1)
        XCTAssertEqual(summary.failures.first?.kind, .cycle)
        let copiedData = await destination.fileData(at: "/target/folder/ok.txt")
        XCTAssertEqual(copiedData, Data("ok".utf8))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private actor MemoryTransferEndpoint: FileTransferEndpoint {
    enum Node {
        case file(Data)
        case directory(identity: String)
    }

    enum TestError: Error { case readFailed, removeFailed, alreadyExists }

    private var nodes: [String: Node]
    private var failedReadPaths: Set<String> = []
    private var retryableReadPaths: Set<String> = []
    private var failsTemporaryRemoval = false
    private var losesNextTemporaryCreateResponse = false
    private var losesNextReplaceResponse = false
    private var losesNextRemoveResponseAt: String?
    private var losesNextTemporaryRemoveResponse = false
    private(set) var readCount = 0
    private var readDelay: Duration?
    private var concurrentReads = 0
    private(set) var maximumConcurrentReads = 0
    private var suspendWrite = false
    private var writeSuspension: CheckedContinuation<Void, Never>?

    init(nodes: [String: Node]) {
        self.nodes = nodes
    }

    func metadata(at path: String) async throws -> FileTransferMetadata? {
        guard let node = nodes[path] else { return nil }
        switch node {
        case .file(let data):
            return FileTransferMetadata(kind: .file, sizeBytes: Int64(data.count), canonicalIdentity: nil)
        case .directory(let identity):
            return FileTransferMetadata(kind: .directory, sizeBytes: 0, canonicalIdentity: identity)
        }
    }

    func children(at path: String) async throws -> [String] {
        let prefix = path == "/" ? "/" : path + "/"
        return nodes.keys.filter { candidate in
            guard candidate.hasPrefix(prefix), candidate != path else { return false }
            return !candidate.dropFirst(prefix.count).contains("/")
        }.sorted()
    }

    func readChunk(at path: String, offset: Int64, length: Int) async throws -> Data {
        readCount += 1
        if retryableReadPaths.remove(path) != nil {
            throw FileTransferEndpointError.retryable("Connection lost")
        }
        if failedReadPaths.contains(path) { throw TestError.readFailed }
        concurrentReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, concurrentReads)
        defer { concurrentReads -= 1 }
        if let readDelay {
            try await Task.sleep(for: readDelay)
        }
        guard case .file(let data)? = nodes[path] else { return Data() }
        let start = min(Int(offset), data.count)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func createDirectory(at path: String) async throws {
        nodes[path] = .directory(identity: path)
    }

    func createTemporaryFile(at path: String) async throws {
        guard nodes[path] == nil else { throw TestError.alreadyExists }
        nodes[path] = .file(Data())
        if losesNextTemporaryCreateResponse {
            losesNextTemporaryCreateResponse = false
            throw FileTransferEndpointError.retryable("Connection lost after create")
        }
    }

    func writeChunk(_ data: Data, to path: String, offset: Int64) async throws {
        var contents: Data
        if case .file(let existing)? = nodes[path] { contents = existing } else { contents = Data() }
        if contents.count < Int(offset) {
            contents.append(Data(repeating: 0, count: Int(offset) - contents.count))
        }
        contents.replaceSubrange(Int(offset)..<contents.count, with: data)
        nodes[path] = .file(contents)
        if suspendWrite {
            suspendWrite = false
            await withCheckedContinuation { continuation in
                writeSuspension = continuation
            }
        }
    }

    func replaceItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        nodes[path] = nodes[temporaryPath]
        nodes.removeValue(forKey: temporaryPath)
        if losesNextReplaceResponse {
            losesNextReplaceResponse = false
            throw FileTransferEndpointError.retryable("Connection lost after replace")
        }
    }

    func removeItem(at path: String) async throws {
        if failsTemporaryRemoval, FileTransferCoordinator.isTemporaryPath(path) {
            throw TestError.removeFailed
        }
        nodes.removeValue(forKey: path)
        if losesNextTemporaryRemoveResponse, FileTransferCoordinator.isTemporaryPath(path) {
            losesNextTemporaryRemoveResponse = false
            throw FileTransferEndpointError.retryable("Connection lost after cleanup")
        }
        if losesNextRemoveResponseAt == path {
            losesNextRemoveResponseAt = nil
            throw FileTransferEndpointError.retryable("Connection lost after remove")
        }
    }

    func failReads(at path: String) {
        failedReadPaths.insert(path)
    }

    func failNextReadRetryably(at path: String) {
        retryableReadPaths.insert(path)
    }

    func failTemporaryRemovals() {
        failsTemporaryRemoval = true
    }

    func commitNextTemporaryCreationThenLoseConnection() {
        losesNextTemporaryCreateResponse = true
    }

    func commitNextReplacementThenLoseConnection() {
        losesNextReplaceResponse = true
    }

    func commitNextRemovalThenLoseConnection(at path: String) {
        losesNextRemoveResponseAt = path
    }

    func commitNextTemporaryRemovalThenLoseConnection() {
        losesNextTemporaryRemoveResponse = true
    }

    func delayEachRead(by duration: Duration) {
        readDelay = duration
    }

    func suspendNextWrite() {
        suspendWrite = true
    }

    func waitForSuspendedWrite() async {
        while writeSuspension == nil {
            await Task.yield()
        }
    }

    func resumeSuspendedWrite() {
        writeSuspension?.resume()
        writeSuspension = nil
    }

    func fileData(at path: String) -> Data? {
        guard case .file(let data)? = nodes[path] else { return nil }
        return data
    }

    func kind(at path: String) -> FileTransferItemKind? {
        guard let node = nodes[path] else { return nil }
        switch node {
        case .file: return .file
        case .directory: return .directory
        }
    }

    var containsTemporaryItems: Bool {
        nodes.keys.contains(where: FileTransferCoordinator.isTemporaryPath)
    }
}
