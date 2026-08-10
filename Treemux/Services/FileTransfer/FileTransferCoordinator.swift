import Foundation
import Observation

@MainActor
@Observable
final class FileTransferCoordinator {
    nonisolated static let temporaryMarker = ".treemux-transfer-"
    nonisolated static let temporarySuffix = ".part"

    private struct PendingFile: Sendable {
        let sourcePath: String
        let destinationPath: String
        let sizeBytes: Int64
    }

    private enum TransferControl: Error {
        case cancelled
    }

    private let source: any FileTransferEndpoint
    private let destination: any FileTransferEndpoint
    private let chunkSize: Int
    private let concurrencyLimit: Int
    private var conflictContinuation: CheckedContinuation<FileTransferConflictDecision, Never>?
    private var retryContinuations: [CheckedContinuation<Bool, Never>] = []
    private var cancellationRequested = false
    private var pendingFiles: [PendingFile] = []

    private(set) var state: FileTransferState = .idle
    private(set) var direction: FileTransferDirection?
    private(set) var currentItem: String?
    private(set) var summary = FileTransferSummary()
    private(set) var pendingConflict: FileTransferConflict?
    private(set) var pendingRetryableError: FileTransferRetryableError?

    init(
        source: any FileTransferEndpoint,
        destination: any FileTransferEndpoint,
        chunkSize: Int = 256 * 1024,
        concurrencyLimit: Int = 3
    ) {
        self.source = source
        self.destination = destination
        self.chunkSize = max(1, chunkSize)
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    func start(
        direction: FileTransferDirection,
        sources: [String],
        destinationRoot: String
    ) async -> FileTransferSummary {
        guard state != .running, state != .waitingForConflict, state != .paused else { return summary }
        self.direction = direction
        summary = FileTransferSummary()
        cancellationRequested = false
        pendingConflict = nil
        pendingRetryableError = nil
        pendingFiles = []
        state = .running

        for (index, sourcePath) in sources.enumerated() {
            if cancellationRequested {
                summary.cancelledItems += sources.count - index
                break
            }
            let destinationPath = Self.join(destinationRoot, Self.name(of: sourcePath))
            await prepareTransferItem(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                ancestry: []
            )
            await transferPendingFiles()
        }

        currentItem = nil
        pendingConflict = nil
        pendingRetryableError = nil
        summary.cancelled = cancellationRequested
        if cancellationRequested {
            summary.cancelledItems += max(
                0,
                summary.discoveredItems
                    - summary.completedItems
                    - summary.skippedItems
                    - summary.failedItems
            )
        }
        state = .completed
        return summary
    }

    func resolveConflict(_ decision: FileTransferConflictDecision) {
        guard let continuation = conflictContinuation else { return }
        conflictContinuation = nil
        pendingConflict = nil
        if decision == .cancelAll {
            cancellationRequested = true
            state = .cancelling
        } else {
            state = .running
        }
        continuation.resume(returning: decision)
    }

    func cancel() {
        guard state == .running || state == .waitingForConflict || state == .paused else { return }
        cancellationRequested = true
        state = .cancelling
        if conflictContinuation != nil {
            resolveConflict(.cancelAll)
        }
        let continuations = retryContinuations
        retryContinuations = []
        pendingRetryableError = nil
        continuations.forEach { $0.resume(returning: false) }
    }

    func retry() {
        guard state == .paused else { return }
        pendingRetryableError = nil
        state = .running
        let continuations = retryContinuations
        retryContinuations = []
        continuations.forEach { $0.resume(returning: true) }
    }

    private func prepareTransferItem(
        sourcePath: String,
        destinationPath: String,
        ancestry: Set<String>
    ) async {
        guard !cancellationRequested else { return }
        currentItem = sourcePath

        do {
            guard let sourceMetadata = try await performWithRetry({
                try await source.metadata(at: sourcePath)
            }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            summary.discoveredItems += 1
            if sourceMetadata.kind == .file {
                summary.totalBytes += sourceMetadata.sizeBytes
            }

            if sourceMetadata.kind == .directory,
               let identity = sourceMetadata.canonicalIdentity,
               ancestry.contains(identity) {
                recordFailure(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    kind: .cycle,
                    message: String(localized: "Transfer stopped because a symbolic link points to an ancestor.")
                )
                return
            }

            if let destinationMetadata = try await performWithRetry({
                try await destination.metadata(at: destinationPath)
            }) {
                let mergesDirectories = sourceMetadata.kind == .directory
                    && destinationMetadata.kind == .directory
                if !mergesDirectories {
                    let decision = await requestConflict(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        sourceKind: sourceMetadata.kind,
                        destinationKind: destinationMetadata.kind
                    )
                    switch decision {
                    case .skip:
                        summary.skippedItems += 1
                        return
                    case .cancelAll:
                        return
                    case .overwrite:
                        if sourceMetadata.kind == .directory || destinationMetadata.kind == .directory {
                            try await performRecoverableMutation(
                                operation: { try await destination.removeItem(at: destinationPath) },
                                committed: {
                                    try await destination.metadata(at: destinationPath) == nil
                                }
                            )
                        }
                    }
                }
            }

            guard !cancellationRequested else { return }
            switch sourceMetadata.kind {
            case .file:
                pendingFiles.append(PendingFile(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    sizeBytes: sourceMetadata.sizeBytes
                ))
            case .directory:
                if try await performWithRetry({
                    try await destination.metadata(at: destinationPath)
                }) == nil {
                    try await performRecoverableMutation(
                        operation: { try await destination.createDirectory(at: destinationPath) },
                        committed: {
                            try await destination.metadata(at: destinationPath)?.kind == .directory
                        }
                    )
                }
                summary.completedItems += 1
                var nextAncestry = ancestry
                if let identity = sourceMetadata.canonicalIdentity {
                    nextAncestry.insert(identity)
                }
                let children = try await performWithRetry {
                    try await source.children(at: sourcePath)
                }
                for (index, child) in children.enumerated() {
                    if cancellationRequested {
                        summary.cancelledItems += children.count - index
                        break
                    }
                    await prepareTransferItem(
                        sourcePath: child,
                        destinationPath: Self.join(destinationPath, Self.name(of: child)),
                        ancestry: nextAncestry
                    )
                }
            }
        } catch TransferControl.cancelled {
            cancellationRequested = true
        } catch {
            recordFailure(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                kind: .operation,
                message: error.localizedDescription
            )
        }
    }

    private func transferPendingFiles() async {
        let files = pendingFiles
        pendingFiles = []
        guard !files.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            let initialCount = min(concurrencyLimit, files.count)
            for _ in 0..<initialCount {
                let file = files[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    await self?.transferPendingFile(file)
                }
            }

            while await group.next() != nil {
                guard !cancellationRequested, state == .running, nextIndex < files.count else { continue }
                let file = files[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    await self?.transferPendingFile(file)
                }
            }
        }
    }

    private func transferPendingFile(_ file: PendingFile) async {
        guard !cancellationRequested else { return }
        currentItem = file.sourcePath

        do {
            try await transferFile(
                sourcePath: file.sourcePath,
                destinationPath: file.destinationPath,
                sizeBytes: file.sizeBytes
            )
            summary.completedItems += 1
        } catch TransferControl.cancelled {
            cancellationRequested = true
        } catch {
            recordFailure(
                sourcePath: file.sourcePath,
                destinationPath: file.destinationPath,
                kind: .operation,
                message: error.localizedDescription
            )
        }
    }

    private func transferFile(
        sourcePath: String,
        destinationPath: String,
        sizeBytes: Int64
    ) async throws {
        let temporaryPath = Self.temporaryPath(for: destinationPath)
        try await performRecoverableMutation(
            operation: { try await destination.createTemporaryFile(at: temporaryPath) },
            committed: { try await destination.metadata(at: temporaryPath) != nil }
        )

        do {
            var offset: Int64 = 0
            while offset < sizeBytes {
                guard !cancellationRequested else { throw TransferControl.cancelled }
                let requestedLength = min(chunkSize, Int(sizeBytes - offset))
                let data = try await performWithRetry {
                    try await source.readChunk(
                        at: sourcePath,
                        offset: offset,
                        length: requestedLength
                    )
                }
                guard !data.isEmpty else {
                    throw CocoaError(.fileReadUnknown)
                }
                try await performWithRetry {
                    try await destination.writeChunk(data, to: temporaryPath, offset: offset)
                }
                offset += Int64(data.count)
                summary.completedBytes += Int64(data.count)
            }
            guard !cancellationRequested else { throw TransferControl.cancelled }
            try await performRecoverableMutation(
                operation: {
                    try await destination.replaceItem(
                        at: destinationPath,
                        withTemporaryItemAt: temporaryPath
                    )
                },
                committed: {
                    let temporary = try await destination.metadata(at: temporaryPath)
                    let final = try await destination.metadata(at: destinationPath)
                    return temporary == nil
                        && final?.kind == .file
                        && final?.sizeBytes == sizeBytes
                }
            )
        } catch {
            do {
                try await performRecoverableMutation(
                    respectingCancellation: false,
                    operation: { try await destination.removeItem(at: temporaryPath) },
                    committed: { try await destination.metadata(at: temporaryPath) == nil }
                )
            } catch {
                summary.failures.append(FileTransferFailure(
                    sourcePath: sourcePath,
                    destinationPath: temporaryPath,
                    kind: .cleanup,
                    message: error.localizedDescription
                ))
            }
            throw error
        }
    }

    private func performWithRetry<T>(_ operation: () async throws -> T) async throws -> T {
        while true {
            guard !cancellationRequested else { throw TransferControl.cancelled }
            do {
                return try await operation()
            } catch FileTransferEndpointError.retryable(let message) {
                let shouldRetry = await waitForRetry(message: message)
                guard shouldRetry else { throw TransferControl.cancelled }
            }
        }
    }

    private func performRecoverableMutation(
        respectingCancellation: Bool = true,
        operation: () async throws -> Void,
        committed: () async throws -> Bool
    ) async throws {
        while true {
            if respectingCancellation, cancellationRequested {
                throw TransferControl.cancelled
            }
            do {
                try await operation()
                return
            } catch FileTransferEndpointError.retryable(let message) {
                let shouldRetry = await waitForRetry(message: message)
                guard shouldRetry else { throw TransferControl.cancelled }
                if try await performWithRetry(
                    respectingCancellation: respectingCancellation,
                    committed
                ) {
                    return
                }
            }
        }
    }

    private func performWithRetry<T>(
        respectingCancellation: Bool,
        _ operation: () async throws -> T
    ) async throws -> T {
        while true {
            if respectingCancellation, cancellationRequested {
                throw TransferControl.cancelled
            }
            do {
                return try await operation()
            } catch FileTransferEndpointError.retryable(let message) {
                let shouldRetry = await waitForRetry(message: message)
                guard shouldRetry else { throw TransferControl.cancelled }
            }
        }
    }

    private func waitForRetry(message: String) async -> Bool {
        if pendingRetryableError == nil {
            pendingRetryableError = FileTransferRetryableError(message: message)
        }
        state = .paused
        return await withCheckedContinuation { continuation in
            retryContinuations.append(continuation)
        }
    }

    private func requestConflict(
        sourcePath: String,
        destinationPath: String,
        sourceKind: FileTransferItemKind,
        destinationKind: FileTransferItemKind
    ) async -> FileTransferConflictDecision {
        pendingConflict = FileTransferConflict(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            sourceKind: sourceKind,
            destinationKind: destinationKind
        )
        state = .waitingForConflict
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
        }
    }

    private func recordFailure(
        sourcePath: String,
        destinationPath: String,
        kind: FileTransferFailureKind,
        message: String
    ) {
        summary.failedItems += 1
        summary.failures.append(FileTransferFailure(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            kind: kind,
            message: message
        ))
    }

    private static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func join(_ parent: String, _ child: String) -> String {
        if parent == "/" { return "/" + child }
        return parent.hasSuffix("/") ? parent + child : parent + "/" + child
    }

    nonisolated static func temporaryPath(for destinationPath: String) -> String {
        destinationPath + temporaryMarker + UUID().uuidString + temporarySuffix
    }

    nonisolated static func isTemporaryPath(_ path: String) -> Bool {
        path.contains(temporaryMarker) && path.hasSuffix(temporarySuffix)
    }
}
