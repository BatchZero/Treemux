//
//  WorkspaceSidebarView.swift
//  Treemux
//

import SwiftUI

/// Sidebar view displaying the list of workspaces with an "Open Project" button.
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar content
            List(selection: $store.selectedWorkspaceID) {
                // Local projects section
                Section {
                    ForEach(store.localWorkspaces) { workspace in
                        WorkspaceRow(workspace: workspace)
                            .tag(workspace.id)
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

/// A single row in the workspace sidebar list.
struct WorkspaceRow: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: workspaceIcon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 13))
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            // Show worktrees if any
            if !workspace.worktrees.isEmpty {
                ForEach(workspace.worktrees) { worktree in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                        Text(worktree.branch ?? worktree.path.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(worktree.isMainWorktree ? .primary : .secondary)
                            .lineLimit(1)
                        if worktree.isMainWorktree {
                            Text("current")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                    }
                    .padding(.leading, 20)
                }
            } else if let branch = workspace.currentBranch {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
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
