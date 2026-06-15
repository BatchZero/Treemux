//
//  LocalFileBrowserDataSource.swift
//  Treemux

import Foundation

final class LocalFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    private let queue = DispatchQueue(label: "treemux.localfs", qos: .userInitiated)

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await runOnQueue {
            let parentURL = URL(fileURLWithPath: path)
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            // Use contentsOfDirectory(at:) for resource keys but re-derive each
            // child's path via appendingPathComponent so that symlinks in the
            // temporary directory hierarchy (e.g. /var → /private/var on macOS)
            // are not transparently resolved, keeping paths stable for callers.
            let contents = try fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: keys, options: [])
            return try contents.map { rawURL -> FileNode in
                let stableURL = parentURL.appendingPathComponent(rawURL.lastPathComponent)
                return try Self.makeNode(from: stableURL)
            }
            .sorted(by: Self.naturalOrder)
        }
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            return FileMetadata(
                path: path,
                sizeBytes: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                isDirectory: values.isDirectory ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false
            )
        }
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size: Int64
            if let n = attrs[.size] as? NSNumber {
                size = n.int64Value
            } else if let i = attrs[.size] as? Int64 {
                size = i
            } else if let i = attrs[.size] as? Int {
                size = Int64(i)
            } else {
                size = 0
            }
            if size > Int64(maxBytes) {
                throw FileBrowserError.fileTooLarge(path: path, sizeBytes: size, limit: Int64(maxBytes))
            }
            return try Data(contentsOf: url)
        }
    }

    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data {
        try await runOnQueue {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            // FileHandle.read returns up to the requested count; never throws
            // on EOF, so empty / short files just yield short Data.
            return handle.readData(ofLength: maxBytes)
        }
    }

    func writeFile(_ path: String, data: Data) async throws {
        try await runOnQueue {
            let url = URL(fileURLWithPath: path)
            try data.write(to: url, options: .atomic)
        }
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        // Local: just return the path itself.
        URL(fileURLWithPath: path)
    }

    // MARK: - helpers

    private static func makeNode(from url: URL) throws -> FileNode {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let kind: FileNode.Kind
        if values.isSymbolicLink == true {
            // Resolve target lazily — readlink not exposed via URLResourceKey.
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            kind = .symlink(target: target)
        } else if values.isDirectory == true {
            kind = .directory
        } else {
            kind = .file
        }
        return FileNode(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            kind: kind,
            sizeBytes: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate
        )
    }

    /// Natural ordering: directories first, then case-insensitive alpha.
    private static func naturalOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private func runOnQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
