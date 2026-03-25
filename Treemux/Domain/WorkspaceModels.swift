//
//  WorkspaceModels.swift
//  Treemux
//

import Foundation

// MARK: - Persistent Records (Codable)

/// The kind of workspace: local repository, bare terminal, or remote SSH.
enum WorkspaceKindRecord: String, Codable {
    case repository
    case localTerminal
    case remote
}

/// A serializable record representing a single workspace.
struct WorkspaceRecord: Codable {
    let id: UUID
    let kind: WorkspaceKindRecord
    let name: String
    let repositoryPath: String?
    let isPinned: Bool
    let isArchived: Bool
    let sshTarget: SSHTarget?
    let worktreeStates: [WorktreeSessionStateRecord]
}

/// Persisted state for a single worktree session within a workspace.
struct WorktreeSessionStateRecord: Codable {
    let worktreePath: String
    let branch: String?
    let tabs: [WorkspaceTabStateRecord]
    let selectedTabID: UUID?
}

/// Persisted state for a single tab inside a worktree session.
struct WorkspaceTabStateRecord: Codable {
    let id: UUID
    let title: String
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
}

/// A snapshot of a single pane for serialization.
struct PaneSnapshot: Codable {
    let id: UUID
    let backend: SessionBackendConfiguration
    let workingDirectory: String?
}

/// Top-level persisted state containing all workspaces.
struct PersistedWorkspaceState: Codable {
    let version: Int
    let selectedWorkspaceID: UUID?
    let workspaces: [WorkspaceRecord]
}

// MARK: - Runtime Models

/// A worktree within a git repository.
struct WorktreeModel: Identifiable {
    let id: UUID
    let path: URL
    let branch: String?
    let headCommit: String?
    let isMainWorktree: Bool
}

/// A snapshot of repository state at a point in time.
struct RepositorySnapshot {
    let currentBranch: String?
    let headCommit: String?
    let worktrees: [WorktreeModel]
    let status: RepositoryStatusSnapshot?
}

/// Summary of repository working-tree status.
struct RepositoryStatusSnapshot {
    let changedFileCount: Int
    let aheadCount: Int
    let behindCount: Int
    let untrackedCount: Int
}
