//
//  WorkspaceOutlineSidebar.swift
//  Treemux

import SwiftUI

/// NSViewRepresentable that bridges the AppKit NSOutlineView sidebar
/// into SwiftUI, using SidebarCoordinator as the coordinator.
struct WorkspaceOutlineSidebar: NSViewRepresentable {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var theme: ThemeManager

    /// Called when a context menu "Rename" is chosen. Params: (workspaceID, currentName).
    var onRequestRename: (UUID, String) -> Void
    /// Called when a context menu "Delete" is chosen. Param: workspaceID.
    var onRequestDelete: (UUID) -> Void

    func makeCoordinator() -> SidebarCoordinator {
        SidebarCoordinator()
    }

    func makeNSView(context: Context) -> SidebarContainerView {
        let container = SidebarContainerView()
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.theme = theme
        coordinator.requestRename = onRequestRename
        coordinator.requestDelete = onRequestDelete
        coordinator.attach(container)
        return container
    }

    func updateNSView(_ nsView: SidebarContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.requestRename = onRequestRename
        coordinator.requestDelete = onRequestDelete

        let workspaces = store.localWorkspaces + store.remoteWorkspaceGroups.flatMap(\.targets)
        coordinator.apply(
            workspaces: workspaces,
            selectedWorkspaceID: store.selectedWorkspaceID,
            theme: theme
        )
    }
}
