//
//  WorkspaceDetailView.swift
//  Treemux

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the split pane layout with terminal sessions.
/// When a specific worktree is selected, shows that worktree's session controller.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let controller = store.activeSessionController {
            WorkspaceSessionDetailView(controller: controller)
                .id(store.selectedWorkspaceID)
        }
    }
}

/// Observes the session controller directly so that layout mutations
/// (e.g. splitPane) propagate to SplitNodeView. Follows the same pattern
/// as Liney's WorkspaceSessionDetailView.
private struct WorkspaceSessionDetailView: View {
    @ObservedObject var controller: WorkspaceSessionController

    var body: some View {
        SplitNodeView(sessionController: controller, node: controller.layout)
    }
}
