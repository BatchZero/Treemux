//
//  WorkspaceDetailView.swift
//  Treemux

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the tab bar (when 2+ tabs), split pane layout, or empty state.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            WorkspaceTabContainerView(workspace: workspace)
                .id(workspace.id)
        }
    }
}

/// Container that manages tab bar visibility and routes to the active tab's content.
private struct WorkspaceTabContainerView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar: shown when 2+ tabs
            if workspace.tabs.count > 1 {
                WorkspaceTabBarView(workspace: workspace)
            }

            // Content area
            if let controller = workspace.sessionController {
                WorkspaceSessionDetailView(controller: controller)
                    .id(workspace.activeTabID)
            } else {
                EmptyTabStateView {
                    workspace.createTab()
                }
            }
        }
    }
}

/// Observes the session controller directly so that layout mutations
/// (e.g. splitPane) propagate to SplitNodeView.
private struct WorkspaceSessionDetailView: View {
    @ObservedObject var controller: WorkspaceSessionController

    var body: some View {
        SplitNodeView(sessionController: controller, node: controller.layout)
    }
}
