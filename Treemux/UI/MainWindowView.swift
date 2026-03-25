//
//  MainWindowView.swift
//  Treemux
//

import SwiftUI

/// Main window view with a NavigationSplitView containing a sidebar and detail pane.
struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore

    /// Toggle the sidebar by forwarding the action to NSSplitViewController.
    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 276, max: 400)
        } detail: {
            if store.selectedWorkspace != nil {
                WorkspaceDetailView()
            } else {
                ContentUnavailableView {
                    Label(
                        String(localized: "No Project Selected"),
                        systemImage: "folder"
                    )
                } description: {
                    Text(String(localized: "Select or open a project to get started"))
                }
            }
        }
        // Remove the default sidebar toggle and add a custom one pinned to the leading edge.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
            }
        }
    }
}
