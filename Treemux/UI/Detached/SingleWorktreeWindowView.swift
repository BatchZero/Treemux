//
//  SingleWorktreeWindowView.swift
//  Treemux

import SwiftUI

/// Body of a detached child window showing one worktree's active tab without
/// a sidebar or tab bar.
///
/// Resolves terminal and file-browser content via NON-mutating accessors so the
/// detached window does NOT switch `WorkspaceModel.activeWorktreePath` out from
/// under another view. Controllers remain shared for the same worktree/tab pair,
/// while the selected worktree and active tab stay scoped to this window.
struct SingleWorktreeWindowView: View {
    @Bindable var workspace: WorkspaceModel
    let worktree: WorktreeModel
    @Environment(\.windowCommandContext) private var commandContext

    var body: some View {
        let _ = commandContext?.revision
        Group {
            if commandContext?.activeTab?.kind == .fileBrowser,
               let controller = commandContext?.activeFileBrowserController {
                FileBrowserTabContentView(controller: controller)
            } else if let controller = commandContext?.activeSessionController
                        ?? workspace.sessionController(forWorktreePathReadOnly: worktree.path.path) {
                WorkspaceSessionDetailView(
                    controller: controller,
                    onCloseTab: {
                        // Closing the last pane in a detached worktree window
                        // closes that worktree's terminal tab. Only close when
                        // the workspace is currently viewing this worktree;
                        // otherwise the inactive tab state has no live UI to
                        // dismiss and there is nothing to do here.
                        if workspace.activeWorktreePath == worktree.path.path,
                           let tabID = workspace.activeTabID {
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
    }
}
