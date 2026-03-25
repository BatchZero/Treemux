//
//  WorkspaceDetailView.swift
//  Treemux
//

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the split pane layout with terminal sessions.
/// When a specific worktree is selected, shows that worktree's session controller.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    /// Resolves the active session controller based on workspace vs worktree selection.
    private var activeController: WorkspaceSessionController? {
        guard let workspace = store.selectedWorkspace else { return nil }
        if let worktree = store.selectedWorktree {
            return workspace.sessionController(forWorktreePath: worktree.path.path)
        }
        return workspace.sessionController
    }

    var body: some View {
        if let controller = activeController {
            SplitNodeView(
                sessionController: controller,
                node: controller.layout
            )
            .id(store.selectedWorkspaceID)
        }
    }
}
