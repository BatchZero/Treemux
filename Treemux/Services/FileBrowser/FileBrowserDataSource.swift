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

    func listDirectory(_ path: String) async throws -> [FileNode]
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
}
