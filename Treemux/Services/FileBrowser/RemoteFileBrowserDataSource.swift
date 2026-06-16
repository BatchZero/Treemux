//
//  RemoteFileBrowserDataSource.swift
//  Treemux

import Foundation

final class RemoteFileBrowserDataSource: FileBrowserDataSource {
    let supportsWrite = true
    let sshTarget: SSHTarget
    private let service: SFTPService

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
        try await service.connect(target: sshTarget)
    }

    /// Connect using interactive password auth, bypassing SSH key auth entirely.
    /// Invoked by `FileBrowserTabController.retryWithPassword(_:)` after the
    /// initial key-auth attempt surfaces `.authenticationFailed`.
    func connectWithPassword(_ password: String) async throws {
        try await service.connectWithPassword(target: sshTarget, password: password)
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
                        kind: kind, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt)
    }

    func listDirectory(_ path: String) async throws -> [FileNode] {
        try await ensureConnected()
        let rich = try await service.listAllEntries(at: path)
        return rich.map(Self.node(from:)).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
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
