//
//  FileViewerPanelView.swift
//  Treemux

import SwiftUI

struct FileViewerPanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    var body: some View {
        Text("File viewer placeholder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
