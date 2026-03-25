//
//  WorkspaceDetailView.swift
//  Treemux
//

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the split pane layout with terminal sessions.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            SplitNodeView(
                sessionController: workspace.sessionController,
                node: workspace.sessionController.layout
            )
            .id(workspace.id)
        }
    }
}
