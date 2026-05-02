//
//  FileBrowserTabContentView.swift
//  Treemux

import SwiftUI

struct FileBrowserTabContentView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        // HSplitView consults `idealWidth` only on initial layout per view instance;
        // once the user drags the divider, that cached position wins over updates.
        GeometryReader { geo in
            HSplitView {
                FileTreePanelView(controller: controller)
                    .frame(
                        minWidth: 180,
                        idealWidth: max(180, geo.size.width * 0.2)
                    )
                FileViewerPanelView(controller: controller)
                    .frame(minWidth: 200)
            }
        }
        .task {
            await controller.loadRoot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .treemuxSaveCurrentFile)) { _ in
            Task { try? await controller.saveCurrentFile() }
        }
    }
}
