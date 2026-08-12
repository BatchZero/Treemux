//
//  SingleWorktreeWindowView.swift
//  Treemux

import SwiftUI

/// Body of a detached child window showing a single worktree's terminal
/// session (no sidebar, no tab bar).
///
/// On appear it switches the parent workspace to the target worktree path so
/// the correct saved tab state is loaded, then renders only the session
/// detail view for the active terminal tab. Closing the last pane closes the
/// terminal tab on the workspace.
struct SingleWorktreeWindowView: View {
    @Bindable var workspace: WorkspaceModel
    let worktree: WorktreeModel

    var body: some View {
        Group {
            if let controller = workspace.sessionController(forWorktreePath: worktree.path.path) {
                WorkspaceSessionDetailView(
                    controller: controller,
                    onCloseTab: {
                        // Closing the last pane in a detached worktree window
                        // closes that terminal tab on the shared workspace.
                        if let tabID = workspace.activeTabID {
                            workspace.closeTab(tabID)
                        }
                    }
                )
            } else {
                ContentUnavailableView(
                    String(localized: "No Terminal Session"),
                    systemImage: "terminal",
                    description: Text(String(localized: "This worktree has no active terminal session."))
                )
            }
        }
        .onAppear {
            // Ensure the workspace is on this worktree's saved tab state so
            // sessionController(forWorktreePath:) returns the right controller.
            workspace.switchToWorktree(worktree.path.path)
        }
    }
}
