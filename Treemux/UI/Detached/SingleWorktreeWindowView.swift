//
//  SingleWorktreeWindowView.swift
//  Treemux

import SwiftUI

/// Body of a detached child window showing a single worktree's terminal
/// session (no sidebar, no tab bar).
///
/// Resolves the worktree's terminal session via the NON-mutating accessor
/// (`sessionController(forWorktreePathReadOnly:)`) so the detached window does
/// NOT switch the shared `WorkspaceModel.activeWorktreePath` out from under the
/// main window's `WorkspaceDetailView` — the parent workspace stays where the
/// user left it in the main sidebar. The session controller itself is shared
/// (same (worktree path, tab) pair), so typing in the detached window updates
/// the same session. Closing the last pane closes that worktree's terminal tab.
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
