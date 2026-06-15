//
//  DirectoryTreeCachePersistence.swift
//  Treemux

import Foundation
import Crypto

/// Persists `DirectoryTreeSnapshot`s to `~/.treemux[-debug]/directory-tree-cache/`,
/// one JSON file per `(identity, rootPath)`. The filename is an MD5 of the key
/// so arbitrarily long/odd remote paths map to a safe, fixed-length name.
/// Mirrors `AppSettingsPersistence`'s atomic-write pattern.
struct DirectoryTreeCachePersistence {
    private let fileManager: FileManager
    private let baseDirectory: URL?

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
    }

    func save(_ snapshot: DirectoryTreeSnapshot, identity: String) throws {
        let dir = cacheDirectoryURL()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(identity: identity, rootPath: snapshot.rootPath), options: .atomic)
    }

    func load(identity: String, rootPath: String) -> DirectoryTreeSnapshot? {
        let url = fileURL(identity: identity, rootPath: rootPath)
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(DirectoryTreeSnapshot.self, from: data),
              snap.rootPath == rootPath
        else { return nil }
        return snap
    }

    // MARK: - Paths

    private func cacheDirectoryURL() -> URL {
        let base = baseDirectory ?? treemuxStateDirectoryURL(fileManager: fileManager)
        return base.appendingPathComponent("directory-tree-cache", isDirectory: true)
    }

    private func fileURL(identity: String, rootPath: String) -> URL {
        let key = identity + "|" + rootPath
        let digest = Insecure.MD5.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL().appendingPathComponent(hex + ".json")
    }
}
