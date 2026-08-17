//
//  DetachedRootView.swift
//  Treemux

import SwiftUI

/// Dispatches to the correct detached child window body based on the
/// `DetachedNodeRef`. Hosted by `WindowContext` as the root view of a torn-off
/// window. The store filters out stale refs during `restoreChildWindows`, but
/// this view is defensive: if the referenced node is missing at render time
/// it shows a "no longer available" placeholder instead of crashing.
struct DetachedRootView: View {
    let ref: DetachedNodeRef

    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        switch ref {
        case .workspace(let id):
            if let ws = store.workspaces.first(where: { $0.id == id }) {
                SingleWorkspaceWindowView(workspace: ws)
            } else {
                missingNodeView
            }
        case .worktree(let wsID, let wtID):
            if let ws = store.workspaces.first(where: { $0.id == wsID }),
               let wt = ws.worktrees.first(where: { $0.id == wtID }) {
                // Keep the parent project visible so a detached worktree retains
                // the same folder actions and project/worktree context as a
                // detached workspace. The dragged worktree is selected first.
                SingleWorkspaceWindowView(
                    workspace: ws,
                    initialSelection: wt.id,
                    scopedWorktreeID: wt.id
                )
            } else {
                missingNodeView
            }
        case .remoteGroup(let key):
            RemoteGroupWindowView(groupKey: key)
        }
    }

    /// Shown when the detached node's underlying workspace/worktree no longer
    /// exists. Should be rare (restore filters invalid refs), but guards the
    /// render path against races (e.g. a workspace deleted while the window
    /// is on screen).
    private var missingNodeView: some View {
        ContentUnavailableView(
            String(localized: "This project is no longer available."),
            systemImage: "exclamationmark.triangle"
        )
    }
}
