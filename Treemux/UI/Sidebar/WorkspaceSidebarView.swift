//
//  WorkspaceSidebarView.swift
//  Treemux

import AppKit
import SwiftUI

/// Sidebar view displaying the list of workspaces with an "Open Project" button.
/// Projects with multiple worktrees show a disclosure group; single-worktree
/// projects display a simple row with the branch name underneath.
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager

    /// Tracks which row the cursor is hovering over.
    @State private var hoveredID: UUID?

    // Rename dialog state
    @State private var renamingWorkspaceID: UUID?
    @State private var renameText: String = ""

    // Delete confirmation state
    @State private var deletingWorkspaceID: UUID?

    // Open project sheet state
    @State private var showOpenProjectSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar content – `selection:` binding enables native click-to-select
            // and drag-to-reorder; @FocusState keeps the list focused so the
            // selection highlight is always blue (not gray).
            List(selection: $store.selectedWorkspaceID) {
                // Local projects section
                Section {
                    ForEach(store.localWorkspaces) { workspace in
                        WorkspaceRowGroup(workspace: workspace, hoveredID: $hoveredID)
                            .contextMenu {
                                if workspace.kind == .repository {
                                    Button {
                                        renameText = workspace.name
                                        renamingWorkspaceID = workspace.id
                                    } label: {
                                        Label(String(localized: "Rename…"), systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        deletingWorkspaceID = workspace.id
                                    } label: {
                                        Label(String(localized: "Delete"), systemImage: "trash")
                                    }
                                }
                            }
                    }
                    .onMove { source, destination in
                        store.moveLocalWorkspace(from: source, to: destination)
                    }
                } header: {
                    Text(String(localized: "Local Projects"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }

                // Remote server sections
                ForEach(store.remoteWorkspaceGroups, id: \.key) { group in
                    Section {
                        ForEach(group.targets) { workspace in
                            WorkspaceRowGroup(workspace: workspace)
                                .contextMenu {
                                    Button {
                                        renameText = workspace.name
                                        renamingWorkspaceID = workspace.id
                                    } label: {
                                        Label(String(localized: "Rename…"), systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        deletingWorkspaceID = workspace.id
                                    } label: {
                                        Label(String(localized: "Delete"), systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.green)
                            Text(remoteGroupLabel(group.targets.first))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .background(
                // Disables the system's built-in selection highlight (which
                // flickers gray/blue depending on focus) so that our custom
                // .listRowBackground is the only visible row background.
                OutlineViewConfigurator()
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )

            // Bottom bar with "Open Project" button
            Divider()
            Button {
                showOpenProjectSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text(String(localized: "Open Project..."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .background(theme.sidebarBackground)
        // Rename alert
        .alert(String(localized: "Rename Project"), isPresented: Binding(
            get: { renamingWorkspaceID != nil },
            set: { if !$0 { renamingWorkspaceID = nil } }
        )) {
            TextField(String(localized: "Project Name"), text: $renameText)
            Button(String(localized: "Cancel"), role: .cancel) {
                renamingWorkspaceID = nil
            }
            Button(String(localized: "Rename")) {
                if let id = renamingWorkspaceID {
                    store.renameWorkspace(id, to: renameText)
                }
                renamingWorkspaceID = nil
            }
        }
        // Delete confirmation alert
        .alert(String(localized: "Delete Project?"), isPresented: Binding(
            get: { deletingWorkspaceID != nil },
            set: { if !$0 { deletingWorkspaceID = nil } }
        )) {
            Button(String(localized: "Cancel"), role: .cancel) {
                deletingWorkspaceID = nil
            }
            Button(String(localized: "Delete"), role: .destructive) {
                if let id = deletingWorkspaceID {
                    store.removeWorkspace(id)
                }
                deletingWorkspaceID = nil
            }
        } message: {
            Text(String(localized: "This will remove the project from the sidebar. Files on disk will not be affected."))
        }
        .sheet(isPresented: $showOpenProjectSheet) {
            OpenProjectSheet()
        }
    }

    /// Formats the section header label for a remote workspace group.
    private func remoteGroupLabel(_ workspace: WorkspaceModel?) -> String {
        guard let target = workspace?.sshTarget else { return "Remote" }
        if let user = target.user {
            return "\(target.displayName) (\(user)@)"
        }
        return target.displayName
    }

}

// MARK: - AppKit: disable system selection highlight

/// An invisible NSViewRepresentable that finds the sidebar's NSOutlineView
/// and sets `selectionHighlightStyle = .none`.  This removes the system's
/// focus-dependent blue/gray highlight so we can draw our own via
/// `.listRowBackground` (always blue when selected, gray when hovered).
private struct OutlineViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.configure(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply in case the outline view was recreated by SwiftUI.
        DispatchQueue.main.async { Self.configure(from: nsView) }
    }

    private static func configure(from view: NSView) {
        guard let window = view.window,
              let outlineView = findOutlineView(in: window.contentView) else { return }
        if outlineView.selectionHighlightStyle != .none {
            outlineView.selectionHighlightStyle = .none
        }
    }

    private static func findOutlineView(in view: NSView?) -> NSOutlineView? {
        guard let view = view else { return nil }
        if let ov = view as? NSOutlineView { return ov }
        for subview in view.subviews {
            if let ov = findOutlineView(in: subview) { return ov }
        }
        return nil
    }
}

// MARK: - Row background helper

/// Blue when selected, gray when hovered, clear otherwise.
/// This is the sole source of row highlight now that the system's built-in
/// selection drawing is disabled via `selectionHighlightStyle = .none`.
@ViewBuilder
func sidebarRowBackground(isSelected: Bool, isHovered: Bool) -> some View {
    if isSelected {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor)
    } else if isHovered {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.gray.opacity(0.2))
    } else {
        Color.clear
    }
}

// MARK: - WorkspaceRowGroup

/// Groups a workspace row: uses a DisclosureGroup when there are multiple
/// worktrees, or a plain row when there is zero or one worktree.
struct WorkspaceRowGroup: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel
    @Binding var hoveredID: UUID?
    @State private var isExpanded: Bool = true

    private var isWorkspaceSelected: Bool {
        store.selectedWorkspaceID == workspace.id
    }

    var body: some View {
        if workspace.worktrees.count > 1 {
            // Multiple worktrees: collapsible disclosure group
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(workspace.worktrees) { worktree in
                    WorktreeRow(worktree: worktree, hoveredID: $hoveredID)
                        .tag(worktree.id)
                }
                .onMove { source, destination in
                    store.moveWorktree(in: workspace, from: source, to: destination)
                }
            } label: {
                ProjectLabel(
                    workspace: workspace,
                    showCurrent: isWorkspaceSelected
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .onHover { isHovering in
                    if isHovering { hoveredID = workspace.id }
                    else if hoveredID == workspace.id { hoveredID = nil }
                }
            }
            .listRowBackground(sidebarRowBackground(
                isSelected: isWorkspaceSelected,
                isHovered: hoveredID == workspace.id
            ))
            .tag(workspace.id)
        } else {
            // Single or no worktrees: simple row with optional branch info
            VStack(alignment: .leading, spacing: 2) {
                ProjectLabel(
                    workspace: workspace,
                    showCurrent: isWorkspaceSelected
                )
                if let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 20)
                }
            }
            .onHover { isHovering in
                if isHovering { hoveredID = workspace.id }
                else if hoveredID == workspace.id { hoveredID = nil }
            }
            .listRowBackground(sidebarRowBackground(
                isSelected: isWorkspaceSelected,
                isHovered: hoveredID == workspace.id
            ))
            .tag(workspace.id)
        }
    }
}

// MARK: - ProjectLabel

/// Displays a project icon, name, and optional "current" badge.
struct ProjectLabel: View {
    @ObservedObject var workspace: WorkspaceModel
    var showCurrent: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: workspaceIcon)
                .foregroundStyle(iconColor)
                .font(.system(size: 13))
            Text(workspace.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if showCurrent {
                Spacer()
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
    }

    // MARK: - Icon helpers

    private var workspaceIcon: String {
        switch workspace.kind {
        case .localTerminal:
            return "apple.terminal"
        case .repository:
            return "folder.fill"
        case .remote:
            return "globe"
        }
    }

    private var iconColor: Color {
        switch workspace.kind {
        case .localTerminal:
            return .green
        case .repository:
            return .blue
        case .remote:
            return .orange
        }
    }
}

// MARK: - WorktreeRow

/// A single worktree row shown inside a disclosure group.
struct WorktreeRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    let worktree: WorktreeModel
    @Binding var hoveredID: UUID?

    private var isSelected: Bool {
        store.selectedWorkspaceID == worktree.id
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 12))
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
        .onHover { isHovering in
            if isHovering { hoveredID = worktree.id }
            else if hoveredID == worktree.id { hoveredID = nil }
        }
        .listRowBackground(sidebarRowBackground(
            isSelected: isSelected,
            isHovered: hoveredID == worktree.id
        ))
    }
}
