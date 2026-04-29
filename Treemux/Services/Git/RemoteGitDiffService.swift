//
//  RemoteGitDiffService.swift
//  Treemux
//

import Foundation

/// Remote implementation of `GitDiffService` — runs the same git commands over SSH
/// using the shared `SFTPService.runCommand(_:in:)` helper.
struct RemoteGitDiffService: GitDiffService {
    let service: SFTPService

    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk] {
        let cmd = "git diff --no-color HEAD -- \(Self.shellQuote(path))"
        let raw = try await service.runCommand(cmd, in: repoRoot)
        return LocalGitDiffService.parseDiff(raw)
    }

    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus] {
        let raw = try await service.runCommand("git status --porcelain", in: repoRoot)
        return LocalGitDiffService.parseStatus(raw)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
