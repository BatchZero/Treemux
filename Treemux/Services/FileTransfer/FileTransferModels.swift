import Foundation

enum FileTransferDirection: Sendable {
    case upload
    case download
}

enum FileTransferItemKind: Sendable, Equatable {
    case file
    case directory
}

struct FileTransferMetadata: Sendable, Equatable {
    let kind: FileTransferItemKind
    let sizeBytes: Int64
    let canonicalIdentity: String?
}

protocol FileTransferEndpoint: Sendable {
    func metadata(at path: String) async throws -> FileTransferMetadata?
    func children(at path: String) async throws -> [String]
    func readChunk(at path: String, offset: Int64, length: Int) async throws -> Data
    func createDirectory(at path: String) async throws
    func createTemporaryFile(at path: String) async throws
    func writeChunk(_ data: Data, to path: String, offset: Int64) async throws
    func replaceItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws
    func removeItem(at path: String) async throws
}

enum FileTransferConflictDecision: Sendable {
    case overwrite
    case skip
    case cancelAll
}

struct FileTransferConflict: Identifiable, Sendable, Equatable {
    let id = UUID()
    let sourcePath: String
    let destinationPath: String
    let sourceKind: FileTransferItemKind
    let destinationKind: FileTransferItemKind
}

enum FileTransferFailureKind: Sendable, Equatable {
    case cycle
    case operation
}

struct FileTransferFailure: Sendable, Equatable {
    let sourcePath: String
    let destinationPath: String
    let kind: FileTransferFailureKind
    let message: String
}

struct FileTransferSummary: Sendable, Equatable {
    var discoveredItems = 0
    var completedItems = 0
    var skippedItems = 0
    var failedItems = 0
    var totalBytes: Int64 = 0
    var completedBytes: Int64 = 0
    var cancelled = false
    var failures: [FileTransferFailure] = []
}

enum FileTransferState: Sendable, Equatable {
    case idle
    case running
    case waitingForConflict
    case cancelling
    case completed
    case failed
}
