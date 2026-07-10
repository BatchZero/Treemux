//
//  WorkspaceOutlineSidebar.swift
//  Treemux

import SwiftUI

/// NSViewRepresentable that bridges the AppKit NSOutlineView sidebar
/// into SwiftUI, using SidebarCoordinator as the coordinator.
struct WorkspaceOutlineSidebar: NSViewRepresentable {
    let store: WorkspaceStore
    let theme: ThemeManager

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
        // Explicit tracked read: keeps updateNSView re-firing on theme
        // switches (parity with the old whole-object @ObservedObject
        // invalidation). The sidebar island refreshes via .themeDidChange,
        // but the coordinator's re-apply pass still expects this update.
        _ = theme.activeTheme

        // Explicit tracked reads: parity with the old whole-object
        // @ObservedObject invalidation. apply() reads workspaces/groups/
        // collapsedSections within this call stack (auto-tracked); the
        // generation counter is the designated invalidation signal for
        // metadata refreshes, and selection drives the highlight sync.
        _ = store.workspaceMetadataGeneration
        _ = store.selectedWorkspaceID

        let coordinator = context.coordinator
        coordinator.store = store
        coordinator.requestRename = onRequestRename
        coordinator.requestDelete = onRequestDelete

        coordinator.apply(
            store: store,
            selectedWorkspaceID: store.selectedWorkspaceID,
            theme: theme
        )
    }
}
