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
                Section(String(localized: "Local Projects")) {
                    ForEach(store.localWorkspaces) { workspace in
                        WorkspaceRow(workspace: workspace)
                            .tag(workspace.id)
                    }
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
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            if let branch = workspace.currentBranch {
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
