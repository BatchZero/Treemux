//
//  SingleWorkspaceWindowView.swift
//  Treemux

import SwiftUI

/// Body of a detached child window showing a single workspace (no sidebar).
///
/// Renders the full tab container for the given workspace so the torn-off
/// window behaves like the main detail pane for that project — tab bar,
/// split layout, file-browser tabs and all. The workspace is passed by value
/// (a reference to the shared `@Observable` model), so edits propagate back
/// to the main window's store without any extra plumbing.
struct SingleWorkspaceWindowView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        WorkspaceTabContainerView(workspace: workspace)
            .id(workspace.id)
    }
}
