//
//  WorkspaceDetailView.swift
//  Treemux
//

import SwiftUI

/// Detail view for the selected workspace.
/// Placeholder — Task 12 will replace this with actual terminal pane embedding.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            VStack {
                Text(workspace.name)
                    .font(.title2)
                if let branch = workspace.currentBranch {
                    Text("Branch: \(branch)")
                        .foregroundStyle(.secondary)
                }
                Text(String(localized: "Terminal panes will appear here"))
                    .foregroundStyle(.tertiary)
                    .padding(.top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
