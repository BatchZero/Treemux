//
//  WorkspaceSidebarView.swift
//  Treemux
//

import SwiftUI

/// Sidebar view displaying the list of workspaces with an "Open Project" button.
/// Projects with multiple worktrees show a disclosure group; single-worktree
/// projects display a simple row with the branch name underneath.
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar content
            List(selection: $store.selectedWorkspaceID) {
                // Local projects section
                Section {
                    ForEach(store.localWorkspaces) { workspace in
                        WorkspaceRowGroup(workspace: workspace)
                    }
                } header: {
                    Text(String(localized: "Local Projects"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }

                // Remote server sections would go here (Task 18)
            }
            .listStyle(.sidebar)

            // Bottom bar with "Open Project" button
            Divider()
            Button {
                store.addWorkspaceFromOpenPanel()
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
        .background(Color(red: 0.07, green: 0.08, blue: 0.09))
    }
}

/// Groups a workspace row: uses a DisclosureGroup when there are multiple
/// worktrees, or a plain row when there is zero or one worktree.
struct WorkspaceRowGroup: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var isExpanded: Bool = true

    var body: some View {
        if workspace.worktrees.count > 1 {
            // Multiple worktrees: collapsible disclosure group
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(workspace.worktrees) { worktree in
                    WorktreeRow(worktree: worktree)
                        .tag(workspace.id) // Selecting a worktree selects the parent workspace
                }
            } label: {
                ProjectLabel(workspace: workspace)
            }
            .tag(workspace.id)
        } else {
            // Single or no worktrees: simple row with optional branch info
            VStack(alignment: .leading, spacing: 2) {
                ProjectLabel(workspace: workspace)
                if let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 20)
                }
            }
            .tag(workspace.id)
        }
    }
}

/// Displays a project icon and name.
struct ProjectLabel: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: workspaceIcon)
                .foregroundStyle(iconColor)
                .font(.system(size: 13))
            Text(workspace.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
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

/// A single worktree row shown inside a disclosure group.
struct WorktreeRow: View {
    let worktree: WorktreeModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            if worktree.isMainWorktree {
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
    }
}
