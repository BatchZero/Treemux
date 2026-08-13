//
//  RemoteGroupWindowView.swift
//  Treemux

import SwiftUI

/// Body of a detached child window showing a single remote server section.
///
/// Lists every workspace belonging to the remote group key in a narrow
/// navigation sidebar, and shows the selected workspace's detail pane.
/// Selection is local to this window (the main sidebar is unaffected) and
/// defaults to the first workspace when nothing is selected.
struct RemoteGroupWindowView: View {
    let groupKey: String

    @Environment(WorkspaceStore.self) private var store
    @Environment(ThemeManager.self) private var theme
    @State private var localSelection: UUID?

    /// Workspaces belonging to this remote group, in store order.
    private var workspaces: [WorkspaceModel] {
        store.workspacesInRemoteGroup(groupKey)
    }

    /// The workspace to render in the detail pane.
    private var selectedWorkspace: WorkspaceModel? {
        if let id = localSelection,
           let ws = workspaces.first(where: { $0.id == id }) {
            return ws
        }
        return workspaces.first
    }

    /// Display title for the window's navigation title. `remoteGroupDisplayTitle`
    /// takes an `SSHTarget` (not a group-key string), so derive the target from
    /// the group's first workspace. Falls back to the raw group key when the
    /// group is empty or no target is available.
    private var displayTitle: String {
        if let ws = workspaces.first, let target = ws.sshTarget {
            return WorkspaceStore.remoteGroupDisplayTitle(for: target)
        }
        return groupKey
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $localSelection) {
                ForEach(workspaces) { ws in
                    // SidebarNodeRow takes plain-value deps (no environment
                    // injection — see the crash note on the type). The activity
                    // indicator is derived here from the workspace state, the
                    // same way SidebarCoordinator computes it.
                    SidebarNodeRow(
                        node: SidebarNodeItem(kind: .workspace(ws)),
                        store: store,
                        theme: theme,
                        isSelected: selectedWorkspace?.id == ws.id,
                        activityIndicator: ws.hasAnyRunningSessions ? .working : .none
                    )
                    .tag(ws.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        localSelection = ws.id
                    }
                }
            }
            .navigationTitle(displayTitle)
            .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            if let ws = selectedWorkspace {
                WorkspaceTabContainerView(workspace: ws)
                    .id(ws.id)
            } else {
                ContentUnavailableView(
                    String(localized: "No Project Selected"),
                    systemImage: "folder",
                    description: Text(String(localized: "This server has no projects."))
                )
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
    }
}
