//
//  DirectoryTreeSnapshot.swift
//  Treemux

import Foundation

/// The on-disk shape of a cached remote directory tree. Persisted per
/// `(cache identity, root path)` so a project reopens instantly from cache
/// before the live background refresh lands. `childrenByPath` stores the
/// **unfiltered** listing for each visited directory (including the root);
/// directories in `truncatedDirs` had their listing capped at fetch time.
struct DirectoryTreeSnapshot: Codable, Equatable, Sendable {
    var rootPath: String
    var childrenByPath: [String: [FileNode]]
    var truncatedDirs: [String]
    var fetchedAt: Date

    init(rootPath: String,
         childrenByPath: [String: [FileNode]],
         truncatedDirs: [String],
         fetchedAt: Date) {
        self.rootPath = rootPath
        self.childrenByPath = childrenByPath
        self.truncatedDirs = truncatedDirs
        self.fetchedAt = fetchedAt
    }
}
