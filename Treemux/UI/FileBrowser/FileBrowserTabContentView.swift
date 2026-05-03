//
//  FileBrowserTabContentView.swift
//  Treemux

import SwiftUI

struct FileBrowserTabContentView: View {
    @ObservedObject var controller: FileBrowserTabController

    // Default 2:8 split. HStack + explicit widths + SplitDivider gives reliable
    // initial layout and per-tab drag state, unlike HSplitView's idealWidth cache.
    @State private var fraction: Double = 0.2

    private let dividerThickness: CGFloat = 6
    private let leftMin: CGFloat = 180
    private let rightMin: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let availableWidth = max(totalWidth - dividerThickness, 1)
            let lowerBound = min(0.95, leftMin / availableWidth)
            let upperBound = max(0.05, 1 - rightMin / availableWidth)
            let clampedFraction = min(max(fraction, lowerBound), upperBound)
            let leftWidth = availableWidth * clampedFraction
            let rightWidth = availableWidth - leftWidth

            HStack(spacing: 0) {
                FileTreePanelView(controller: controller)
                    .frame(width: leftWidth)
                SplitDivider(
                    axis: .horizontal,
                    fraction: clampedFraction,
                    availableLength: availableWidth
                ) { newFraction in
                    fraction = min(max(newFraction, lowerBound), upperBound)
                }
                FileViewerPanelView(controller: controller)
                    .frame(width: rightWidth)
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
