//
//  WorkspaceSidebarView.swift
//  Treemux

import SwiftUI

/// Sidebar view displaying the list of workspaces with an "Open Project" button.
/// Uses an AppKit NSOutlineView (via WorkspaceOutlineSidebar) for rendering.
struct WorkspaceSidebarView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ThemeManager.self) private var theme
    @Environment(LanguageManager.self) private var languageManager
    @Environment(WindowManager.self) private var windowManager

    // Rename dialog state
    @State private var renamingWorkspaceID: UUID?
    @State private var renameText: String = ""

    // Delete confirmation state
    @State private var deletingWorkspaceID: UUID?

    // Open project sheet state
    @State private var showOpenProjectSheet = false

    var body: some View {
        @Bindable var store = store
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
                },
                onDetachNode: { [weak windowManager] ref in
                    // Tear off: hand the ref to the WindowManager, which creates
                    // the detached child window and records the node as detached
                    // so the sidebar filters it out. Weak capture keeps the
                    // coordinator closure from retaining the manager.
                    windowManager?.detach(ref)
                }
            )

            // Bottom bar with "Open Project" button
            Divider()
            Button {
                showOpenProjectSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text("Open Project...")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .background(theme.sidebarBackground)
        // Rename alert
        .alert("Rename Project", isPresented: Binding(
            get: { renamingWorkspaceID != nil },
            set: { if !$0 { renamingWorkspaceID = nil } }
        )) {
            TextField("Project Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                renamingWorkspaceID = nil
            }
            Button("Rename") {
                if let id = renamingWorkspaceID {
                    store.renameWorkspace(id, to: renameText)
                }
                renamingWorkspaceID = nil
            }
        }
        // Delete confirmation alert
        .alert("Delete Project?", isPresented: Binding(
            get: { deletingWorkspaceID != nil },
            set: { if !$0 { deletingWorkspaceID = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deletingWorkspaceID = nil
            }
            Button("Delete", role: .destructive) {
                if let id = deletingWorkspaceID {
                    store.removeWorkspace(id)
                }
                deletingWorkspaceID = nil
            }
        } message: {
            Text("This will remove the project from the sidebar. Files on disk will not be affected.")
        }
        .sheet(isPresented: $showOpenProjectSheet) {
            OpenProjectSheet()
                .environment(\.locale, languageManager.locale)
        }
        .sheet(item: $store.sidebarIconCustomizationRequest) { request in
            SidebarIconCustomizationSheet(request: request)
                .environment(store)
                .environment(theme)
                .environment(\.locale, languageManager.locale)
        }
    }
}
