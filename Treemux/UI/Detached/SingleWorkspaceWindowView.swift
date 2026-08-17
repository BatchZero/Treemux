//
//  SingleWorkspaceWindowView.swift
//  Treemux

import AppKit
import SwiftUI

/// Body of a detached child window showing one workspace and its worktrees.
///
/// The navigation selection belongs to this child window, so choosing a
/// worktree here never changes the main window's global sidebar selection.
struct SingleWorkspaceWindowView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(WorkspaceStore.self) private var store
    @Environment(ThemeManager.self) private var theme
    @State private var localSelection: UUID?

    /// `initialSelection` lets a worktree tear-off reuse this complete project
    /// layout while opening directly on the worktree that was dragged out.
    init(workspace: WorkspaceModel, initialSelection: UUID? = nil) {
        self.workspace = workspace
        _localSelection = State(initialValue: initialSelection ?? workspace.id)
    }

    private var selectedWorktree: WorktreeModel? {
        guard let localSelection else { return nil }
        return workspace.worktrees.first { $0.id == localSelection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $localSelection) {
                sidebarRow(
                    SidebarNodeItem(kind: .workspace(workspace)),
                    id: workspace.id,
                    activity: workspace.hasAnyRunningSessions ? .working : .none
                )

                ForEach(workspace.worktrees) { worktree in
                    sidebarRow(
                        SidebarNodeItem(kind: .worktree(workspace, worktree)),
                        id: worktree.id,
                        activity: workspace.hasRunningSessions(forWorktreePath: worktree.path.path)
                            ? .working : .none
                    )
                }
            }
            .navigationTitle(workspace.name)
            .navigationSplitViewColumnWidth(min: 180, ideal: 276, max: 400)
        } detail: {
            if let worktree = selectedWorktree {
                SingleWorktreeWindowView(workspace: workspace, worktree: worktree)
                    .id(worktree.id)
            } else {
                WorkspaceTabContainerView(workspace: workspace)
                    .id(workspace.id)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        with: nil
                    )
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .accessibilityLabel("Toggle Sidebar")
                .help("Toggle Sidebar")
            }
        }
        .onAppear {
            let isKnownSelection = localSelection == workspace.id
                || workspace.worktrees.contains { $0.id == localSelection }
            if !isKnownSelection {
                localSelection = workspace.id
            }
        }
    }

    private func sidebarRow(
        _ node: SidebarNodeItem,
        id: UUID,
        activity: SidebarIconActivityIndicator
    ) -> some View {
        SidebarNodeRow(
            node: node,
            store: store,
            theme: theme,
            isSelected: (localSelection ?? workspace.id) == id,
            activityIndicator: activity
        )
        .tag(id)
        .contentShape(Rectangle())
        .onTapGesture {
            localSelection = id
        }
    }
}
