//
//  SidebarNodeRow.swift
//  Treemux

import SwiftUI

/// Dispatches rendering to workspace or worktree row content
/// based on the SidebarNodeItem kind.
/// All dependencies are passed as parameters — no @EnvironmentObject usage.
struct SidebarNodeRow: View {
    let node: SidebarNodeItem
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    var body: some View {
        switch node.kind {
        case .workspace(let ws):
            WorkspaceRowContent(
                workspace: ws,
                store: store,
                theme: theme,
                isSelected: isSelected
            )
        case .worktree(let ws, let wt):
            WorktreeRowContent(
                workspace: ws,
                worktree: wt,
                store: store,
                theme: theme,
                isSelected: isSelected
            )
        }
    }
}

// MARK: - WorkspaceRowContent

/// Displays workspace icon, name, optional branch, and current badge.
struct WorkspaceRowContent: View {
    let workspace: WorkspaceModel
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: workspace),
                size: 22
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.sidebarForeground)
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isSelected {
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && !isSelected ? theme.sidebarSelection.opacity(0.3) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - WorktreeRowContent

/// Displays worktree icon, branch name, and current badge.
struct WorktreeRowContent: View {
    let workspace: WorkspaceModel
    let worktree: WorktreeModel
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: worktree, in: workspace),
                size: 18,
                isActive: isSelected
            )
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(theme.sidebarForeground)
                .lineLimit(1)
            Spacer()
            if isSelected {
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && !isSelected ? theme.sidebarSelection.opacity(0.3) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
