import Foundation

/// Service for interacting with git repositories via CLI commands.
actor GitRepositoryService {

    /// Returns the root directory of the git repository at the given path.
    func repositoryRoot(at path: URL) async throws -> URL {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.notARepository
        }
        return URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns the current branch name at the given path.
    func currentBranch(at path: URL) async throws -> String {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the short hash of the HEAD commit.
    func headCommit(at path: URL) async throws -> String {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--short", "HEAD"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lists all worktrees for the repository at the given path.
    func listWorktrees(at path: URL) async throws -> [WorktreeModel] {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
        return parseWorktreeList(result.output)
    }

    /// Returns a snapshot of the repository's working-tree status.
    func repositoryStatus(at path: URL) async throws -> RepositoryStatusSnapshot {
        async let statusResult = ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            workingDirectory: path
        )
        async let aheadBehindResult = ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
            workingDirectory: path
        )

        let status = try await statusResult
        let lines = status.output.split(separator: "\n")
        let changedCount = lines.filter { !$0.hasPrefix("??") }.count
        let untrackedCount = lines.filter { $0.hasPrefix("??") }.count

        var ahead = 0
        var behind = 0
        if let ab = try? await aheadBehindResult, ab.exitCode == 0 {
            let parts = ab.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        return RepositoryStatusSnapshot(
            changedFileCount: changedCount,
            aheadCount: ahead,
            behindCount: behind,
            untrackedCount: untrackedCount
        )
    }

    /// Inspects the repository and returns a full snapshot of its state.
    func inspectRepository(at path: URL) async throws -> RepositorySnapshot {
        async let branch = currentBranch(at: path)
        async let head = headCommit(at: path)
        async let worktrees = listWorktrees(at: path)
        let status = try? await repositoryStatus(at: path)

        return RepositorySnapshot(
            currentBranch: try await branch,
            headCommit: try await head,
            worktrees: try await worktrees,
            status: status
        )
    }

    /// Creates a new worktree for the given branch at the target path.
    func createWorktree(at repoPath: URL, branch: String, targetPath: URL) async throws {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["worktree", "add", targetPath.path, branch],
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
    }

    /// Removes the worktree at the given path.
    func removeWorktree(at repoPath: URL, worktreePath: URL) async throws {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["worktree", "remove", worktreePath.path],
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
    }

    // MARK: - Parsing

    /// Parses the porcelain output of `git worktree list --porcelain`.
    private func parseWorktreeList(_ output: String) -> [WorktreeModel] {
        var worktrees: [WorktreeModel] = []
        var currentPath: String?
        var currentBranch: String?
        var currentHead: String?
        var isMainWorktree = true

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            if lineStr.isEmpty {
                if let path = currentPath {
                    worktrees.append(WorktreeModel(
                        id: UUID(),
                        path: URL(fileURLWithPath: path),
                        branch: currentBranch,
                        headCommit: currentHead,
                        isMainWorktree: isMainWorktree
                    ))
                }
                currentPath = nil
                currentBranch = nil
                currentHead = nil
                isMainWorktree = false
            } else if lineStr.hasPrefix("worktree ") {
                currentPath = String(lineStr.dropFirst("worktree ".count))
            } else if lineStr.hasPrefix("HEAD ") {
                currentHead = String(lineStr.dropFirst("HEAD ".count).prefix(7))
            } else if lineStr.hasPrefix("branch ") {
                let ref = String(lineStr.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            }
        }

        // Handle the last worktree entry if output doesn't end with empty line
        if let path = currentPath {
            worktrees.append(WorktreeModel(
                id: UUID(),
                path: URL(fileURLWithPath: path),
                branch: currentBranch,
                headCommit: currentHead,
                isMainWorktree: isMainWorktree
            ))
        }

        return worktrees
    }
}

/// Errors that can occur during git operations.
enum GitError: Error, LocalizedError {
    case notARepository
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notARepository: return "Not a git repository"
        case .commandFailed(let msg): return "Git command failed: \(msg)"
        }
    }
}
