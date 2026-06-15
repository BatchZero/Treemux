//
//  DirectoryTreeFetch.swift
//  Treemux

import Foundation

/// The in-memory result of a bulk multi-level directory fetch. `childrenByPath`
/// maps each visited directory path (including the root) to its immediate
/// children. Directories deeper than the fetch reached simply have no key.
/// `truncatedDirs` holds directories whose listing was capped at `entryCap`.
struct DirectoryTreeFetch: Equatable, Sendable {
    var childrenByPath: [String: [FileNode]]
    var truncatedDirs: Set<String>

    init(childrenByPath: [String: [FileNode]] = [:], truncatedDirs: Set<String> = []) {
        self.childrenByPath = childrenByPath
        self.truncatedDirs = truncatedDirs
    }
}

/// Default bulk-fetch strategy: breadth-first over `listDirectory`, one level at
/// a time, up to `maxDepth` levels of directory listings. Used by the local FS
/// source and the Citadel (password-auth) remote path. The system-SSH remote
/// path overrides this with a single `find` round-trip instead.
///
/// Listing is sequential by design: the Citadel SFTP path multiplexes one
/// channel (parallel requests serialize there anyway), and sequential keeps the
/// code free of `Sendable` plumbing around the non-Sendable data sources.
enum BFSTreeLister {
    static func list(using source: any FileBrowserDataSource,
                     root: String,
                     maxDepth: Int,
                     entryCap: Int) async throws -> DirectoryTreeFetch {
        var result: [String: [FileNode]] = [:]
        var truncated: Set<String> = []
        var frontier = [root]
        var depth = 0
        while !frontier.isEmpty && depth < maxDepth {
            var next: [String] = []
            for dir in frontier {
                let kids = try await source.listDirectory(dir)
                let capped: [FileNode]
                if kids.count > entryCap {
                    capped = Array(kids.prefix(entryCap))
                    truncated.insert(dir)
                } else {
                    capped = kids
                }
                result[dir] = capped
                for child in capped where child.isDirectory { next.append(child.path) }
            }
            frontier = next
            depth += 1
        }
        return DirectoryTreeFetch(childrenByPath: result, truncatedDirs: truncated)
    }
}
