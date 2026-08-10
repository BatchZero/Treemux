import Foundation

final class FileBrowserTransferEndpoint: @unchecked Sendable, FileTransferEndpoint {
    private let dataSource: any FileBrowserDataSource

    init(dataSource: any FileBrowserDataSource) {
        self.dataSource = dataSource
    }

    func metadata(at path: String) async throws -> FileTransferMetadata? {
        try await dataSource.transferMetadata(path)
    }

    func children(at path: String) async throws -> [String] {
        try await dataSource.transferChildren(path)
    }

    func readChunk(at path: String, offset: Int64, length: Int) async throws -> Data {
        try await dataSource.readTransferChunk(path, offset: offset, length: length)
    }

    func createDirectory(at path: String) async throws {
        try await dataSource.createDirectory(path)
    }

    func createTemporaryFile(at path: String) async throws {
        try await dataSource.createTransferTemporaryFile(path)
    }

    func writeChunk(_ data: Data, to path: String, offset: Int64) async throws {
        try await dataSource.writeTransferChunk(data, to: path, offset: offset)
    }

    func replaceItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        try await dataSource.replaceTransferItem(at: path, withTemporaryItemAt: temporaryPath)
    }

    func removeItem(at path: String) async throws {
        try await dataSource.removeTransferItem(path)
    }
}
