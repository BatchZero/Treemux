//
//  MainWindowView.swift
//  Treemux
//

import SwiftUI

/// Placeholder main window view — Task 11 will replace this with NavigationSplitView.
struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Text("Treemux — \(store.workspaces.count) workspaces")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
