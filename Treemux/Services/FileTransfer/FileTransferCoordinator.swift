import Foundation
import Observation

@MainActor
@Observable
final class FileTransferCoordinator {
    nonisolated static let temporarySuffix = ".treemux-transfer-part"

    private enum TransferControl: Error {
        case cancelled
    }

    private let source: any FileTransferEndpoint
    private let destination: any FileTransferEndpoint
    private let chunkSize: Int
    private let concurrencyLimit: Int
    private var conflictContinuation: CheckedContinuation<FileTransferConflictDecision, Never>?
    private var cancellationRequested = false

    private(set) var state: FileTransferState = .idle
    private(set) var direction: FileTransferDirection?
    private(set) var currentItem: String?
    private(set) var summary = FileTransferSummary()
    private(set) var pendingConflict: FileTransferConflict?

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
        guard state != .running, state != .waitingForConflict else { return summary }
        _ = concurrencyLimit
        self.direction = direction
        summary = FileTransferSummary()
        cancellationRequested = false
        pendingConflict = nil
        state = .running

        for sourcePath in sources {
            if cancellationRequested { break }
            let destinationPath = Self.join(destinationRoot, Self.name(of: sourcePath))
            await transferItem(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                ancestry: []
            )
        }

        currentItem = nil
        pendingConflict = nil
        summary.cancelled = cancellationRequested
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
        guard state == .running || state == .waitingForConflict else { return }
        cancellationRequested = true
        state = .cancelling
        if conflictContinuation != nil {
            resolveConflict(.cancelAll)
        }
    }

    private func transferItem(
        sourcePath: String,
        destinationPath: String,
        ancestry: Set<String>
    ) async {
        guard !cancellationRequested else { return }
        currentItem = sourcePath

        do {
            guard let sourceMetadata = try await source.metadata(at: sourcePath) else {
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

            if let destinationMetadata = try await destination.metadata(at: destinationPath) {
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
                            try await destination.removeItem(at: destinationPath)
                        }
                    }
                }
            }

            guard !cancellationRequested else { return }
            switch sourceMetadata.kind {
            case .file:
                try await transferFile(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    sizeBytes: sourceMetadata.sizeBytes
                )
                summary.completedItems += 1
            case .directory:
                if try await destination.metadata(at: destinationPath) == nil {
                    try await destination.createDirectory(at: destinationPath)
                }
                summary.completedItems += 1
                var nextAncestry = ancestry
                if let identity = sourceMetadata.canonicalIdentity {
                    nextAncestry.insert(identity)
                }
                let children = try await source.children(at: sourcePath)
                for child in children {
                    if cancellationRequested { break }
                    await transferItem(
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

    private func transferFile(
        sourcePath: String,
        destinationPath: String,
        sizeBytes: Int64
    ) async throws {
        let temporaryPath = destinationPath + Self.temporarySuffix
        if try await destination.metadata(at: temporaryPath) != nil {
            try await destination.removeItem(at: temporaryPath)
        }
        try await destination.createTemporaryFile(at: temporaryPath)

        do {
            var offset: Int64 = 0
            while offset < sizeBytes {
                guard !cancellationRequested else { throw TransferControl.cancelled }
                let requestedLength = min(chunkSize, Int(sizeBytes - offset))
                let data = try await source.readChunk(
                    at: sourcePath,
                    offset: offset,
                    length: requestedLength
                )
                guard !data.isEmpty else {
                    throw CocoaError(.fileReadUnknown)
                }
                try await destination.writeChunk(data, to: temporaryPath, offset: offset)
                offset += Int64(data.count)
                summary.completedBytes += Int64(data.count)
            }
            try await destination.replaceItem(
                at: destinationPath,
                withTemporaryItemAt: temporaryPath
            )
        } catch {
            try? await destination.removeItem(at: temporaryPath)
            throw error
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
}
