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
        case .section(let section):
            SectionHeaderRow(section: section, theme: theme)
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

/// Displays workspace icon, name, and optional branch.
struct WorkspaceRowContent: View {
    let workspace: WorkspaceModel
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool

    @State private var isHovered = false

    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasAnyRunningSessions {
            return .working
        }
        if workspace.activeWorktreePath == workspace.repositoryRoot?.path {
            return .current
        }
        return .none
    }

    // Natural height of the two-line case (12pt name + 2pt spacing + 10pt branch).
    // Pinning the VStack to this minHeight keeps single-line rows (no git, or
    // multi-worktree) the same overall height as two-line rows so the project
    // name is vertically centered.
    private static let contentMinHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: workspace),
                size: 22,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.sidebarForeground)
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: Self.contentMinHeight)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.leading, 2)
        .padding(.trailing, 4)
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

    private var activityIndicator: SidebarIconActivityIndicator {
        if workspace.hasRunningSessions(forWorktreePath: worktree.path.path) {
            return .working
        }
        if workspace.activeWorktreePath == worktree.path.path {
            return .current
        }
        return .none
    }

    var body: some View {
        HStack(spacing: 8) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: worktree, in: workspace),
                size: 16,
                usesCircularShape: true,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected
            )
            .frame(width: 24, alignment: .leading)
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.sidebarForeground)
                .lineLimit(1)
            Spacer()
            // Show badge based on workspace model directly, not activity indicator,
            // so it remains visible even when terminal sessions are running.
            if workspace.activeWorktreePath == worktree.path.path {
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
            }
        }
        .padding(.vertical, 1)
        .padding(.leading, 5)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && !isSelected ? theme.sidebarSelection.opacity(0.3) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - SectionHeaderRow

/// Displays a section header for grouping local/remote workspaces.
struct SectionHeaderRow: View {
    let section: SidebarSection
    let theme: ThemeManager

    private var title: String {
        switch section {
        case .local:
            return String(localized: "Local")
        case .remote(_, let displayTitle):
            return displayTitle
        }
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 2)
        .padding(.vertical, 2)
    }
}
