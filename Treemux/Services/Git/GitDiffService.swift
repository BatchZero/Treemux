//
//  GitDiffService.swift
//  Treemux
//

import Foundation

/// Returns per-file diff hunks and workspace-wide file status for use by
/// the editor gutter (G7) and file-tree status badges (G6).
protocol GitDiffService {
    /// Returns hunks for a single file relative to HEAD. `path` is repo-relative.
    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk]

    /// Workspace-wide file status, keyed by repo-relative path.
    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus]
}

/// A contiguous diff region in the new (post-change) file.
struct DiffHunk: Equatable {
    enum Kind: Equatable { case added, modified, removed }
    var newLineRange: ClosedRange<Int>
    var kind: Kind
}

/// Git-status classification for a single file.
enum FileStatus: Equatable {
    case untracked
    case modified
    case added
    case deleted
    case renamed(from: String)
}
