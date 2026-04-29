//
//  LocalGitDiffService.swift
//  Treemux
//

import Foundation

/// Local implementation of `GitDiffService` — shells out to `git` via Process.
struct LocalGitDiffService: GitDiffService {
    func diffHunks(forFile path: String, repoRoot: String) async throws -> [DiffHunk] {
        let raw = try await runGit(["diff", "--no-color", "HEAD", "--", path], in: repoRoot)
        return Self.parseDiff(raw)
    }

    func fileStatus(in repoRoot: String) async throws -> [String: FileStatus] {
        let raw = try await runGit(["status", "--porcelain"], in: repoRoot)
        return Self.parseStatus(raw)
    }

    /// Parses unified-diff output. Looks at `@@ -a,b +c,d @@` headers and emits one hunk per
    /// header keyed on the new (post-change) line range. The current pass tags every hunk
    /// as `.modified`; G7 will draw all stripes the same color, and added/removed refinement
    /// can come later by inspecting `+`/`-` content lines.
    static func parseDiff(_ raw: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("@@") else { continue }
            // @@ -a,b +c,d @@ optional context
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let new = parts[2]   // "+c,d" or "+c"
            guard new.hasPrefix("+") else { continue }
            let trimmed = new.dropFirst()
            let comps = trimmed.split(separator: ",")
            guard let start = Int(comps[0]) else { continue }
            let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
            if count == 0 { continue }
            hunks.append(DiffHunk(newLineRange: start...(start + count - 1), kind: .modified))
        }
        return hunks
    }

    /// Parses `git status --porcelain` output into a path-keyed status map.
    /// The first two characters are the staged/unstaged code; bytes 2 onward are the path.
    /// Renames are emitted as `R<old> -> <new>` and stored under the new path.
    static func parseStatus(_ raw: String) -> [String: FileStatus] {
        var out: [String: FileStatus] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count >= 4 else { continue }
            let codeIdx = line.index(line.startIndex, offsetBy: 2)
            let code = String(line[..<codeIdx])
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            let path = String(line[pathStart...])
            switch code {
            case "??":
                out[path] = .untracked
            case " M", "M ", "MM":
                out[path] = .modified
            case "A ", " A":
                out[path] = .added
            case "D ", " D":
                out[path] = .deleted
            case let c where c.hasPrefix("R"):
                if let arrow = path.range(of: " -> ") {
                    let from = String(path[..<arrow.lowerBound])
                    let to = String(path[arrow.upperBound...])
                    out[to] = .renamed(from: from)
                } else {
                    out[path] = .modified
                }
            default:
                out[path] = .modified
            }
        }
        return out
    }

    private func runGit(_ args: [String], in cwd: String) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
