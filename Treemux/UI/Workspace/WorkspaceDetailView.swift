//
//  WorkspaceDetailView.swift
//  Treemux
//

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the primary terminal pane for the active workspace.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            WorkspaceTerminalContainer(workspace: workspace)
        }
    }
}

// MARK: - Workspace terminal container

/// Ensures a primary ShellSession exists for the workspace and displays it.
private struct WorkspaceTerminalContainer: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        Group {
            if let session = workspace.primarySession {
                TerminalPaneView(session: session)
            } else {
                // Show a brief loading state while the session is being created.
                Color(nsColor: .controlBackgroundColor)
                    .onAppear {
                        workspace.ensurePrimarySession()
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
