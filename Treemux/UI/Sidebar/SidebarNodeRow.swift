//
//  SidebarNodeRow.swift
//  Treemux

import SwiftUI

/// Dispatches rendering to workspace or worktree row content
/// based on the SidebarNodeItem kind.
/// All dependencies are passed as parameters — no @EnvironmentObject usage.
///
/// `activityIndicator` is precomputed by the coordinator from the workspace's
/// running-session state and passed in by value. The row is hosted inside
/// `NSHostingView<AnyView>`, where SwiftUI's diffing of the wrapped view can
/// suppress `@ObservedObject` re-evaluation. Plain-value props always force a
/// fresh view struct, so the body re-runs whenever the indicator changes.
struct SidebarNodeRow: View {
    let node: SidebarNodeItem
    let store: WorkspaceStore
    let theme: ThemeManager
    let isSelected: Bool
    let activityIndicator: SidebarIconActivityIndicator

    var body: some View {
        switch node.kind {
        case .section(let section):
            SectionHeaderRow(section: section, theme: theme)
        case .workspace(let ws):
            WorkspaceRowContent(
                workspace: ws,
                store: store,
                theme: theme,
                isSelected: isSelected,
                activityIndicator: activityIndicator
            )
        case .worktree(let ws, let wt):
            WorktreeRowContent(
                workspace: ws,
                worktree: wt,
                store: store,
                theme: theme,
                isSelected: isSelected,
                activityIndicator: activityIndicator
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
    /// Precomputed by the coordinator. See `SidebarNodeRow` for why we don't
    /// observe workspace state directly inside this row.
    let activityIndicator: SidebarIconActivityIndicator

    @State private var isHovered = false

    // Natural height of the two-line case (12pt name + 2pt spacing + 10pt branch).
    // Pinning the VStack to this minHeight keeps single-line rows (no git, or
    // multi-worktree) the same overall height as two-line rows so the project
    // name is vertically centered.
    private static let contentMinHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: Spacing.xs) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: workspace),
                size: 22,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected,
                activityRingColor: theme.sidebarBackground
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(DesignFonts.sectionTitle)
                    .foregroundStyle(theme.sidebarForeground)
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch, !branch.isEmpty {
                    Text(branch)
                        .font(DesignFonts.dataLayer(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: Self.contentMinHeight)
            Spacer()
            Button {
                let root = workspace.repositoryRoot?.path ?? workspace.activeWorktreePath
                workspace.createFileBrowserTab(rootPath: root, rootKind: .project,
                                              title: workspace.name)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(DesignFonts.chrome(size: 11, weight: .medium))
                    // Hidden until the row is hovered, then revealed.
                    .foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0.0))
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Open File Browser"))
            .padding(.trailing, 2)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.leading, 2)
        .padding(.trailing, Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
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
    /// Precomputed by the coordinator. See `SidebarNodeRow` for why we don't
    /// observe workspace state directly inside this row.
    let activityIndicator: SidebarIconActivityIndicator

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: worktree, in: workspace),
                size: 16,
                usesCircularShape: true,
                activityIndicator: activityIndicator,
                isEmphasized: isSelected,
                activityRingColor: theme.sidebarBackground
            )
            .frame(width: 24, alignment: .leading)
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(DesignFonts.chrome(size: 11, weight: .medium))
                .foregroundStyle(theme.sidebarForeground)
                .lineLimit(1)
            Spacer()
            // Show badge based on workspace model directly, not activity indicator,
            // so it remains visible even when terminal sessions are running.
            if workspace.activeWorktreePath == worktree.path.path {
                SidebarInfoBadge(text: "current", tone: .subtleSuccess)
            }
            Button {
                workspace.createFileBrowserTab(rootPath: worktree.path.path, rootKind: .worktree,
                                              title: worktree.path.lastPathComponent)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(DesignFonts.chrome(size: 11, weight: .medium))
                    // Hidden until the row is hovered, then revealed.
                    .foregroundStyle(theme.textSecondary.opacity(isHovered ? 1.0 : 0.0))
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Open File Browser"))
            .padding(.trailing, 2)
        }
        .padding(.vertical, Spacing.xxs)
        .padding(.leading, Spacing.xxs)
        .padding(.trailing, Spacing.xxs)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
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
                .font(DesignFonts.chromeStrong)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 2)
        .padding(.vertical, Spacing.xxs)
    }
}
