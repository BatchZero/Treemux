//
//  WorkspaceMetadataWatchService.swift
//  Treemux
//

import Foundation

/// Watches .git directory metadata files (HEAD, index, refs/) for changes
/// using DispatchSource file system observers. Fires a debounced callback
/// when any watched path is modified, enabling automatic git status refresh.
@MainActor
final class WorkspaceMetadataWatchService {
    private struct WatchHandle {
        let workspaceID: UUID
        let path: String
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.batchzero.treemux.metadata-watch")
    private var handles: [WatchHandle] = []
    private var pendingCallbacks: [UUID: DispatchWorkItem] = [:]

    deinit {
        // Cancel all sources synchronously; cancel handlers close descriptors.
        for workItem in pendingCallbacks.values { workItem.cancel() }
        pendingCallbacks.removeAll()
        for handle in handles { handle.source.cancel() }
        handles.removeAll()
    }

    // MARK: - Public API

    /// Configures watchers for the given workspaces.
    /// Stops all existing watchers before creating new ones.
    func configure(
        workspaces: [WorkspaceModel],
        onChange: @escaping @Sendable (UUID) -> Void
    ) {
        stopAll()

        for workspace in workspaces {
            let paths = watchPaths(for: workspace)
            for path in Set(paths) {
                startWatching(path: path, workspaceID: workspace.id, onChange: onChange)
            }
        }
    }

    /// Starts watching the git metadata for a single workspace.
    func watch(workspace: WorkspaceModel, onChange: @escaping @Sendable (UUID) -> Void) {
        // Remove any existing watchers for this workspace first
        stopWatching(workspaceID: workspace.id)

        let paths = watchPaths(for: workspace)
        for path in Set(paths) {
            startWatching(path: path, workspaceID: workspace.id, onChange: onChange)
        }
    }

    /// Stops watching a specific workspace.
    func stopWatching(workspaceID: UUID) {
        pendingCallbacks[workspaceID]?.cancel()
        pendingCallbacks.removeValue(forKey: workspaceID)

        let toRemove = handles.filter { $0.workspaceID == workspaceID }
        for handle in toRemove {
            handle.source.cancel()
        }
        handles.removeAll { $0.workspaceID == workspaceID }
    }

    /// Stops all watchers and clears state.
    func stopAll() {
        for workItem in pendingCallbacks.values {
            workItem.cancel()
        }
        pendingCallbacks.removeAll()

        for handle in handles {
            handle.source.cancel()
        }
        handles.removeAll()
    }

    // MARK: - Private

    private func startWatching(
        path: String,
        workspaceID: UUID,
        onChange: @escaping @Sendable (UUID) -> Void
    ) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleCallback(for: workspaceID, onChange: onChange)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()

        handles.append(WatchHandle(
            workspaceID: workspaceID,
            path: path,
            descriptor: descriptor,
            source: source
        ))
    }

    /// Debounces the change callback per workspace to avoid rapid-fire refreshes.
    private func scheduleCallback(
        for workspaceID: UUID,
        onChange: @escaping @Sendable (UUID) -> Void
    ) {
        pendingCallbacks[workspaceID]?.cancel()
        let workItem = DispatchWorkItem {
            onChange(workspaceID)
        }
        pendingCallbacks[workspaceID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Returns the list of file-system paths to watch for a workspace.
    private func watchPaths(for workspace: WorkspaceModel) -> [String] {
        // If worktrees are populated, watch each worktree's git dir.
        if !workspace.worktrees.isEmpty {
            return workspace.worktrees.flatMap { worktree -> [String] in
                guard let gitDirectory = resolveGitDirectory(for: worktree.path.path) else { return [] }
                return gitMetadataPaths(in: gitDirectory)
            }
        }

        // Fall back to the repository root's .git directory.
        guard let root = workspace.repositoryRoot,
              let gitDirectory = resolveGitDirectory(for: root.path) else {
            return []
        }
        return gitMetadataPaths(in: gitDirectory)
    }

    /// Returns the standard set of file-system paths to watch within a git
    /// directory, including the common gitdir's `worktrees/` sub-directory so
    /// external `git worktree add`/`remove` operations are detected.
    ///
    /// - Note: `internal` (rather than `private`) only so the test target can
    ///         exercise it via `@testable import Treemux`. Production callers
    ///         within this file are the only intended consumers.
    func gitMetadataPaths(in gitDirectory: String) -> [String] {
        let base = URL(fileURLWithPath: gitDirectory)
        let common = resolveCommonGitDirectory(for: gitDirectory)
        let commonBase = URL(fileURLWithPath: common)
        return [
            gitDirectory,
            base.appendingPathComponent("HEAD").path,
            base.appendingPathComponent("index").path,
            base.appendingPathComponent("FETCH_HEAD").path,
            base.appendingPathComponent("refs").path,
            base.appendingPathComponent("refs/heads").path,
            base.appendingPathComponent("refs/remotes").path,
            // Watch the common gitdir and its worktrees/ subdirectory so that
            // external `git worktree add`/`remove` operations trigger refresh.
            common,
            commonBase.appendingPathComponent("worktrees").path,
        ]
        .filter { fileManager.fileExists(atPath: $0) }
    }

    /// Resolves the main repository's git directory from any worktree's gitdir.
    /// Linked worktrees contain a `commondir` file inside their gitdir whose
    /// contents are a path (typically relative) pointing back to the main gitdir.
    /// Main worktrees have no `commondir` file, so the input is returned as-is.
    ///
    /// All return paths are standardized so that callers can string-compare /
    /// `Set`-deduplicate them safely (e.g. `/var/...` and `/private/var/...` on
    /// macOS resolve to the same path).
    ///
    /// - Note: `internal` (rather than `private`) only so the test target can
    ///         exercise it via `@testable import Treemux`. Production callers
    ///         should not depend on this method directly.
    func resolveCommonGitDirectory(for gitDirectory: String) -> String {
        let standardize: (String) -> String = {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let commondirURL = URL(fileURLWithPath: gitDirectory).appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commondirURL, encoding: .utf8) else {
            return standardize(gitDirectory)
        }
        let raw = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return standardize(gitDirectory) }

        let resolvedURL: URL
        if raw.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: raw)
        } else {
            resolvedURL = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: gitDirectory))
        }
        return resolvedURL.standardizedFileURL.path
    }

    /// Resolves the actual .git directory, handling both normal repos and worktree links.
    private func resolveGitDirectory(for worktreePath: String) -> String? {
        let dotGitURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        // Standard repository: .git is a directory
        if isDirectory.boolValue {
            return dotGitURL.path
        }

        // Linked worktree: .git is a file containing "gitdir: <path>"
        guard let contents = try? String(contentsOf: dotGitURL, encoding: .utf8) else {
            return nil
        }
        let prefix = "gitdir:"
        guard let line = contents.split(whereSeparator: \.isNewline).first,
              line.lowercased().hasPrefix(prefix) else {
            return nil
        }
        let rawPath = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = URL(fileURLWithPath: rawPath, relativeTo: dotGitURL.deletingLastPathComponent())
        return resolvedURL.standardizedFileURL.path
    }
}
