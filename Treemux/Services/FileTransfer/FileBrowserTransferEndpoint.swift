import Citadel
import Foundation

final class FileBrowserTransferEndpoint: @unchecked Sendable, FileTransferEndpoint {
    private let dataSource: any FileBrowserDataSource

    init(dataSource: any FileBrowserDataSource) {
        self.dataSource = dataSource
    }

    func metadata(at path: String) async throws -> FileTransferMetadata? {
        try await perform { try await dataSource.transferMetadata(path) }
    }

    func children(at path: String) async throws -> [String] {
        try await perform { try await dataSource.transferChildren(path) }
    }

    func readChunk(at path: String, offset: Int64, length: Int) async throws -> Data {
        try await perform { try await dataSource.readTransferChunk(path, offset: offset, length: length) }
    }

    func createDirectory(at path: String) async throws {
        try await perform { try await dataSource.createDirectory(path) }
    }

    func createTemporaryFile(at path: String) async throws {
        try await perform { try await dataSource.createTransferTemporaryFile(path) }
    }

    func writeChunk(_ data: Data, to path: String, offset: Int64) async throws {
        try await perform { try await dataSource.writeTransferChunk(data, to: path, offset: offset) }
    }

    func replaceItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        try await perform {
            try await dataSource.replaceTransferItem(at: path, withTemporaryItemAt: temporaryPath)
        }
    }

    func removeItem(at path: String) async throws {
        try await perform { try await dataSource.removeTransferItem(path) }
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as SFTPServiceError {
            switch error {
            case .notConnected, .authenticationFailed, .connectionLost, .commandTimedOut:
                throw FileTransferEndpointError.retryable(error.localizedDescription)
            default:
                throw error
            }
        } catch SFTPError.connectionClosed {
            throw FileTransferEndpointError.retryable("SFTP connection closed")
        } catch SFTPError.errorStatus(let status)
                    where status.errorCode == .noConnection || status.errorCode == .connectionLost {
            throw FileTransferEndpointError.retryable(status.message)
        } catch is AuthenticationFailed {
            throw FileTransferEndpointError.retryable("SSH authentication failed")
        }
    }
}
