//
//  RemoteFileBrowserDataSource.swift
//  Treemux

import Citadel
import Foundation

actor AsyncSingleFlight {
    private var inFlight: Task<Void, any Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }
}

final class RemoteFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    let sshTarget: SSHTarget
    private let service: SFTPService
    private let connectionGate = AsyncSingleFlight()
    private var retryPassword: String?

    /// Depth cap for recursive name search. Kept local (rather than referencing
    /// `FileBrowserTabController.searchMaxDepth`) to avoid a UI→service dependency.
    private static let searchMaxDepth = 12

    init(sshTarget: SSHTarget, service: SFTPService = SFTPService()) {
        self.sshTarget = sshTarget
        self.service = service
    }

    private func ensureConnected() async throws {
        // Short-circuit on the actor's own connection state. With shared services
        // across a workspace, a per-instance flag would let a fresh data source
        // call `service.connect(target:)` and tear down sibling tabs' sessions
        // (connect() begins with `await disconnect()`).
        if await service.isConnected { return }
        let password = retryPassword
        try await connectionGate.run { [service, sshTarget] in
            if await service.isConnected { return }
            if let password {
                try await service.connectWithPassword(target: sshTarget, password: password)
            } else {
                try await service.connect(target: sshTarget)
            }
        }
    }

    /// Connect using interactive password auth, bypassing SSH key auth entirely.
    /// Invoked by `FileBrowserTabController.retryWithPassword(_:)` after the
    /// initial key-auth attempt surfaces `.authenticationFailed`.
    func connectWithPassword(_ password: String) async throws {
        try await service.connectWithPassword(target: sshTarget, password: password)
        retryPassword = password
    }

    /// Maps an SFTP rich entry to a file-tree node. Shared by `listDirectory`
    /// and the bulk `listTree` path so both produce identical node shapes.
    static func node(from entry: SFTPRichEntry) -> FileNode {
        let kind: FileNode.Kind
        switch entry.kind {
        case .directory: kind = .directory
        case .file: kind = .file
        case .symlink(let target): kind = .symlink(target: target)
        }
        return FileNode(id: entry.path, name: entry.name, path: entry.path,
                        kind: kind, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt,
                        symlinkTargetResolution: entry.symlinkTargetResolution)
    }

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await ensureConnected()
        let rich = try await service.listAllEntries(at: path)
        return rich.map(Self.node(from:)).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func canonicalDirectoryIdentity(_ path: String) async throws -> String {
        try await ensureConnected()
        return try await service.canonicalDirectoryIdentity(path)
    }

    /// Host/port/user-scoped cache identity. Stable across sessions so a project
    /// reopens from the same on-disk cache file.
    var treeCacheIdentity: String? {
        "\(sshTarget.host):\(sshTarget.port):\(sshTarget.user ?? NSUserName())"
    }

    func listTree(_ root: String, maxDepth: Int, entryCap: Int) async throws -> DirectoryTreeFetch {
        try await ensureConnected()
        if await service.supportsBulkCommand {
            let (grouped, truncated) = try await service.listTreeViaCommand(
                root: root, maxDepth: maxDepth, entryCap: entryCap)
            var byPath: [String: [FileNode]] = [:]
            for (dir, entries) in grouped {
                byPath[dir] = entries.map(Self.node(from:))
            }
            return DirectoryTreeFetch(childrenByPath: byPath, truncatedDirs: truncated)
        }
        // Citadel password path: no arbitrary exec → sequential per-dir BFS.
        return try await BFSTreeLister.list(using: self, root: root, maxDepth: maxDepth, entryCap: entryCap)
    }

    func searchNames(root: String, query: String, maxResults: Int, includeHidden: Bool) async throws -> [FileNode] {
        try await ensureConnected()
        let entries = try await service.searchNames(
            root: root, query: query,
            maxDepth: Self.searchMaxDepth, maxResults: maxResults, includeHidden: includeHidden)
        return entries.map(Self.node(from:))
    }

    func fileMetadata(_ path: String) async throws -> FileMetadata {
        try await ensureConnected()
        let s = try await service.stat(path)
        return FileMetadata(path: path, sizeBytes: s.sizeBytes, modifiedAt: s.modifiedAt,
                            isDirectory: s.isDirectory, isSymbolicLink: s.isSymlink)
    }

    func readFile(_ path: String, maxBytes: Int) async throws -> Data {
        try await ensureConnected()
        return try await service.readFile(at: path, maxBytes: maxBytes)
    }

    func readPrefix(_ path: String, maxBytes: Int) async throws -> Data {
        try await ensureConnected()
        return try await service.readPrefix(at: path, maxBytes: maxBytes)
    }

    func writeFile(_ path: String, data: Data) async throws {
        try await ensureConnected()
        try await service.writeFile(at: path, data: data)
    }

    func createDirectory(_ path: String) async throws {
        try await ensureConnected()
        try await service.createDirectory(at: path)
    }

    func createFile(_ path: String) async throws {
        try await ensureConnected()
        try await service.createFile(at: path)
    }

    func transferMetadata(_ path: String) async throws -> FileTransferMetadata? {
        try await ensureConnected()
        do {
            let stat = try await service.stat(path)
            if stat.isDirectory {
                return FileTransferMetadata(
                    kind: .directory,
                    sizeBytes: 0,
                    canonicalIdentity: try await service.canonicalDirectoryIdentity(path)
                )
            }
            if stat.isSymlink {
                let parent = (path as NSString).deletingLastPathComponent
                if let node = try await listDirectory(parent).first(where: { $0.path == path }) {
                    if node.isExpandableDirectory {
                        return FileTransferMetadata(
                            kind: .directory,
                            sizeBytes: 0,
                            canonicalIdentity: try await service.canonicalDirectoryIdentity(path)
                        )
                    }
                    if node.symlinkTargetResolution == .file {
                        let targetStat = try await service.transferTargetStat(path)
                        return Self.transferFileMetadata(
                            stat: stat,
                            resolvedTargetStat: targetStat
                        )
                    }
                }
            }
            return Self.transferFileMetadata(stat: stat, resolvedTargetStat: nil)
        } catch SFTPError.errorStatus(let status) where status.errorCode == .noSuchFile {
            return nil
        } catch SFTPServiceError.notFound {
            return nil
        }
    }

    static func transferFileMetadata(
        stat: SFTPRichStat,
        resolvedTargetStat: SFTPRichStat?
    ) -> FileTransferMetadata {
        FileTransferMetadata(
            kind: .file,
            sizeBytes: resolvedTargetStat?.sizeBytes ?? stat.sizeBytes,
            canonicalIdentity: nil
        )
    }

    func readTransferChunk(_ path: String, offset: Int64, length: Int) async throws -> Data {
        try await ensureConnected()
        return try await service.readTransferChunk(at: path, offset: offset, length: length)
    }

    func createTransferTemporaryFile(_ path: String) async throws {
        try await ensureConnected()
        try await service.createTransferTemporaryFile(at: path)
    }

    func writeTransferChunk(_ data: Data, to path: String, offset: Int64) async throws {
        try await ensureConnected()
        try await service.writeTransferChunk(data, at: path, offset: offset)
    }

    func replaceTransferItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        try await ensureConnected()
        try await service.replaceTransferItem(at: path, withTemporaryItemAt: temporaryPath)
    }

    func removeTransferItem(_ path: String) async throws {
        try await ensureConnected()
        try await service.removeTransferItem(at: path)
    }

    func downloadForQuickLook(_ path: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await ensureConnected()
        // 200 MB hard cap to avoid disk thrash. The caller's large-file gate
        // should already have prompted the user before reaching this path.
        let data = try await service.readFile(at: path, maxBytes: 200 * 1024 * 1024)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try data.write(to: url, options: .atomic)
        return url
    }
}
