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
    let scopedWorktreeID: UUID?
    @Environment(WorkspaceStore.self) private var store
    @Environment(ThemeManager.self) private var theme
    @Environment(\.windowCommandContext) private var commandContext
    @State private var localSelection: UUID?

    /// `initialSelection` lets a worktree tear-off reuse this complete project
    /// layout while opening directly on the worktree that was dragged out.
    init(
        workspace: WorkspaceModel,
        initialSelection: UUID? = nil,
        scopedWorktreeID: UUID? = nil
    ) {
        self.workspace = workspace
        self.scopedWorktreeID = scopedWorktreeID
        _localSelection = State(initialValue: initialSelection ?? workspace.id)
    }

    /// A detached workspace shows its complete worktree list, while a detached
    /// worktree keeps only its own ancestry: parent workspace + dragged child.
    static func visibleWorktrees(
        in workspace: WorkspaceModel,
        scopedTo worktreeID: UUID?
    ) -> [WorktreeModel] {
        guard let worktreeID else { return workspace.worktrees }
        return workspace.worktrees.filter { $0.id == worktreeID }
    }

    private var visibleWorktrees: [WorktreeModel] {
        Self.visibleWorktrees(in: workspace, scopedTo: scopedWorktreeID)
    }

    private var selectedWorktree: WorktreeModel? {
        guard let localSelection else { return nil }
        return visibleWorktrees.first { $0.id == localSelection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $localSelection) {
                sidebarRow(
                    SidebarNodeItem(kind: .workspace(workspace)),
                    id: workspace.id,
                    activity: workspace.hasAnyRunningSessions ? .working : .none
                )

                ForEach(visibleWorktrees) { worktree in
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
                || visibleWorktrees.contains { $0.id == localSelection }
            if !isKnownSelection {
                localSelection = workspace.id
            }
            updateCommandSelection()
        }
        .onChange(of: localSelection) { _, _ in
            updateCommandSelection()
        }
    }

    private func updateCommandSelection() {
        commandContext?.updateSelection(
            workspace: workspace,
            worktreePath: selectedWorktree?.path.path
        )
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
