//
//  FileTreePanelView.swift
//  Treemux

import SwiftUI

struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    var body: some View {
        Text("File tree placeholder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
