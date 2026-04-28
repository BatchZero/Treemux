//
//  FileBrowserTabContentView.swift
//  Treemux

import SwiftUI

struct FileBrowserTabContentView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        HSplitView {
            FileTreePanelView(controller: controller)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 480)
            FileViewerPanelView(controller: controller)
                .frame(minWidth: 200)
        }
        .task {
            await controller.loadRoot()
        }
    }
}
