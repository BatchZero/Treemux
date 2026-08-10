import Foundation

actor LocalFileTransferEndpoint: FileTransferEndpoint {
    private let fileManager = FileManager.default

    func metadata(at path: String) async throws -> FileTransferMetadata? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let identity = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            return FileTransferMetadata(kind: .directory, sizeBytes: 0, canonicalIdentity: identity)
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return FileTransferMetadata(kind: .file, sizeBytes: size, canonicalIdentity: nil)
    }

    func children(at path: String) async throws -> [String] {
        let urls = try fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        let sorted = try urls.sorted { lhs, rhs in
            let lhsDirectory = try lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let rhsDirectory = try rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if lhsDirectory != rhsDirectory { return lhsDirectory }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
        let parent = URL(fileURLWithPath: path)
        return sorted.map { parent.appendingPathComponent($0.lastPathComponent).path }
    }

    func readChunk(at path: String, offset: Int64, length: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    func createDirectory(at path: String) async throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func createTemporaryFile(at path: String) async throws {
        try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
    }

    func writeChunk(_ data: Data, to path: String, offset: Int64) async throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    func replaceItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        let destinationURL = URL(fileURLWithPath: path)
        let temporaryURL = URL(fileURLWithPath: temporaryPath)
        if fileManager.fileExists(atPath: path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func removeItem(at path: String) async throws {
        guard fileManager.fileExists(atPath: path) else { return }
        try fileManager.removeItem(atPath: path)
    }
}
