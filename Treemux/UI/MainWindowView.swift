//
//  MainWindowView.swift
//  Treemux
//

import SwiftUI

/// Main window view with a NavigationSplitView containing a sidebar and detail pane.
struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView()
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
    }
}
