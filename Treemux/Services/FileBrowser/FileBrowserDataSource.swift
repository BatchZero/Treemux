//
//  FileBrowserDataSource.swift
//  Treemux

import Foundation

enum FileBrowserError: LocalizedError {
    case notFound(String)
    case notReadable(String)
    case notWritable(String)
    case fileTooLarge(path: String, sizeBytes: Int64, limit: Int64)
    case decodingFailed(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .notReadable(let p): return "Cannot read file: \(p)"
        case .notWritable(let p): return "Cannot write file: \(p)"
        case .fileTooLarge(let p, let size, let limit):
            return "File too large (\(size) bytes, limit \(limit)): \(p)"
        case .decodingFailed(let p): return "Cannot decode text: \(p)"
        case .underlying(let e): return e.localizedDescription
        }
    }
}

/// Abstracts file system access so the same UI works for local and remote
/// (SFTP) workspaces. All methods are async and may throw FileBrowserError.
protocol FileBrowserDataSource: AnyObject {
    var supportsWrite: Bool { get }

    /// A stable identity for the on-disk directory-tree cache, or `nil` to
    /// disable caching for this source. Local sources return `nil` (the local
    /// FS is already fast); remote sources return a host/port/user-scoped key.
    var treeCacheIdentity: String? { get }

    /// Bulk-fetch multiple directory levels in as few round-trips as possible.
    /// Returns each visited directory's immediate children keyed by directory
    /// path (including `root`). Listings exceeding `entryCap` are truncated and
    /// the directory is added to `truncatedDirs`.
    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch

    func listDirectory(_ path: String) async throws -> [FileNode]
    /// Returns a stable identity for a directory after resolving symbolic links.
    /// Controllers use it for path-local ancestry cycle checks.
    func canonicalDirectoryIdentity(_ path: String) async throws -> String
    func fileMetadata(_ path: String) async throws -> FileMetadata

    /// Reads up to `maxBytes` from the file. Throws `.fileTooLarge` if the file
    /// exceeds `maxBytes`; the caller is expected to check size first via
    /// `fileMetadata` for files larger than the comfort threshold.
    func readFile(_ path: String, maxBytes: Int) async throws -> Data

    /// Reads at most `maxBytes` from the start of the file, truncating
    /// silently if the file is larger. Used for content sniffing where the
    /// caller only needs a small prefix and explicitly does not want a
    /// `fileTooLarge` failure on big files.
    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data

    /// Writes data atomically when possible. Local: temp file + rename; remote:
    /// SFTP write to temp, rename. Caller decides whether to confirm overwrites.
    func writeFile(_ path: String, data: Data) async throws

    /// Returns a URL to a local file usable by Quick Look. For local sources
    /// this is the original path; for remote, downloads to NSTemporaryDirectory.
    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL

    /// Creates a new empty directory at `path` (non-recursive — parent must
    /// exist). Throws if the path already exists or the source is read-only.
    func createDirectory(_ path: String) async throws

    /// Creates a new empty file at `path`. Throws if the path already exists or
    /// the source is read-only.
    func createFile(_ path: String) async throws

    /// Recursively searches names under `root`, returning up to `maxResults`
    /// nodes whose name contains `query` (case-insensitive). Bounded — remote
    /// uses a single server-side `find`; local walks the FS off-thread.
    ///
    /// - Parameter includeHidden: When `false`, the search must not descend
    ///   into hidden directories nor return hidden files/directories — i.e. it
    ///   must not leak entries the tree UI could never display when "Show
    ///   Hidden Files" is off (e.g. `.git/config` under a hidden `.git` dir).
    func searchNames(root: String, query: String, maxResults: Int, includeHidden: Bool) async throws -> [FileNode]

    func transferMetadata(_ path: String) async throws -> FileTransferMetadata?
    func transferChildren(_ path: String) async throws -> [String]
    func readTransferChunk(_ path: String, offset: Int64, length: Int) async throws -> Data
    func createTransferTemporaryFile(_ path: String) async throws
    func writeTransferChunk(_ data: Data, to path: String, offset: Int64) async throws
    func replaceTransferItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws
    func removeTransferItem(_ path: String) async throws
}

extension FileBrowserDataSource {
    var treeCacheIdentity: String? { nil }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        try await BFSTreeLister.list(using: self, root: root, maxDepth: maxDepth, entryCap: entryCap)
    }

    func canonicalDirectoryIdentity(_ path: String) async throws -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func createDirectory(_ path: String) async throws {
        throw FileBrowserError.notWritable(path)
    }
    func createFile(_ path: String) async throws {
        throw FileBrowserError.notWritable(path)
    }
    func searchNames(root: String, query: String, maxResults: Int, includeHidden: Bool) async throws -> [FileNode] {
        []
    }

    func transferMetadata(_ path: String) async throws -> FileTransferMetadata? {
        do {
            let metadata = try await fileMetadata(path)
            let kind: FileTransferItemKind = metadata.isDirectory ? .directory : .file
            let identity = metadata.isDirectory ? try await canonicalDirectoryIdentity(path) : nil
            return FileTransferMetadata(
                kind: kind,
                sizeBytes: metadata.sizeBytes,
                canonicalIdentity: identity
            )
        } catch FileBrowserError.notFound {
            return nil
        }
    }

    func transferChildren(_ path: String) async throws -> [String] {
        try await listDirectory(path).map(\.path)
    }

    func readTransferChunk(_ path: String, offset: Int64, length: Int) async throws -> Data {
        let upperBound = Int(offset) + length
        let data = try await readFile(path, maxBytes: upperBound)
        let start = min(Int(offset), data.count)
        return data.subdata(in: start..<min(start + length, data.count))
    }

    func createTransferTemporaryFile(_ path: String) async throws {
        try await writeFile(path, data: Data())
    }

    func writeTransferChunk(_ data: Data, to path: String, offset: Int64) async throws {
        var existing = try await readFile(path, maxBytes: Int(offset) + data.count)
        if existing.count < Int(offset) {
            existing.append(Data(repeating: 0, count: Int(offset) - existing.count))
        }
        existing.replaceSubrange(Int(offset)..<existing.count, with: data)
        try await writeFile(path, data: existing)
    }

    func replaceTransferItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        throw FileBrowserError.notWritable(path)
    }

    func removeTransferItem(_ path: String) async throws {
        throw FileBrowserError.notWritable(path)
    }
}
