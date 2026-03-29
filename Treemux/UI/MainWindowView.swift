//
//  MainWindowView.swift
//  Treemux

import AppKit
import SwiftUI

/// Main window view with a NavigationSplitView containing a sidebar and detail pane.
struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 276, max: 400)
        } detail: {
            if store.selectedWorkspace != nil {
                WorkspaceDetailView()
            } else {
                ContentUnavailableView {
                    Label(
                        "No Project Selected",
                        systemImage: "folder"
                    )
                } description: {
                    Text("Select or open a project to get started")
                }
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

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let sc = store.activeSessionController,
                       let focused = sc.focusedPaneID {
                        sc.splitPane(focused, axis: .vertical)
                    }
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                }
                .help("Split Down (⌘D)")

                Button {
                    if let sc = store.activeSessionController,
                       let focused = sc.focusedPaneID {
                        sc.splitPane(focused, axis: .horizontal)
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .help("Split Right (⌘⇧D)")

                Button {
                    store.selectedWorkspace?.createTab()
                } label: {
                    Image(systemName: "plus.rectangle")
                }
                .help("New Terminal (⌘T)")

                Button {
                    store.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .sheet(isPresented: $store.showSettings) {
            SettingsSheet()
        }
        .overlay {
            if store.showCommandPalette {
                CommandPaletteView(isPresented: $store.showCommandPalette)
            }
        }
    }
}
