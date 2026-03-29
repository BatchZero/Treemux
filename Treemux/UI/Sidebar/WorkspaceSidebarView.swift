//
//  WorkspaceSidebarView.swift
//  Treemux

import SwiftUI

/// Sidebar view displaying the list of workspaces with an "Open Project" button.
/// Uses an AppKit NSOutlineView (via WorkspaceOutlineSidebar) for rendering.
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager

    // Rename dialog state
    @State private var renamingWorkspaceID: UUID?
    @State private var renameText: String = ""

    // Delete confirmation state
    @State private var deletingWorkspaceID: UUID?

    // Open project sheet state
    @State private var showOpenProjectSheet = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceOutlineSidebar(
                store: store,
                theme: theme,
                onRequestRename: { id, name in
                    renameText = name
                    renamingWorkspaceID = id
                },
                onRequestDelete: { id in
                    deletingWorkspaceID = id
                }
            )

            // Bottom bar with "Open Project" button
            Divider()
            Button {
                showOpenProjectSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text(String(localized: "Open Project..."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .background(theme.sidebarBackground)
        // Rename alert
        .alert(String(localized: "Rename Project"), isPresented: Binding(
            get: { renamingWorkspaceID != nil },
            set: { if !$0 { renamingWorkspaceID = nil } }
        )) {
            TextField(String(localized: "Project Name"), text: $renameText)
            Button(String(localized: "Cancel"), role: .cancel) {
                renamingWorkspaceID = nil
            }
            Button(String(localized: "Rename")) {
                if let id = renamingWorkspaceID {
                    store.renameWorkspace(id, to: renameText)
                }
                renamingWorkspaceID = nil
            }
        }
        // Delete confirmation alert
        .alert(String(localized: "Delete Project?"), isPresented: Binding(
            get: { deletingWorkspaceID != nil },
            set: { if !$0 { deletingWorkspaceID = nil } }
        )) {
            Button(String(localized: "Cancel"), role: .cancel) {
                deletingWorkspaceID = nil
            }
            Button(String(localized: "Delete"), role: .destructive) {
                if let id = deletingWorkspaceID {
                    store.removeWorkspace(id)
                }
                deletingWorkspaceID = nil
            }
        } message: {
            Text(String(localized: "This will remove the project from the sidebar. Files on disk will not be affected."))
        }
        .sheet(isPresented: $showOpenProjectSheet) {
            OpenProjectSheet()
        }
        .sheet(item: $store.sidebarIconCustomizationRequest) { request in
            SidebarIconCustomizationSheet(request: request)
                .environmentObject(store)
                .environmentObject(theme)
        }
    }
}
