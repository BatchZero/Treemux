//
//  SplitNodeView.swift
//  Treemux
//

import SwiftUI

/// Recursively renders a `SessionLayoutNode` tree as nested split panes.
/// Each `.pane` leaf renders a `TerminalPaneView`; each `.split` node
/// renders an HStack or VStack with a draggable divider.
struct SplitNodeView: View {
    @ObservedObject var sessionController: WorkspaceSessionController
    let node: SessionLayoutNode

    var body: some View {
        Group {
            if let zoomedID = sessionController.zoomedPaneID {
                // When zoomed, render only the zoomed pane at full size.
                let session = sessionController.ensureSession(for: zoomedID)
                TerminalPaneView(session: session)
            } else {
                nodeBody
            }
        }
    }

    @ViewBuilder
    private var nodeBody: some View {
        switch node {
        case .pane(let leaf):
            let session = sessionController.ensureSession(for: leaf.paneID)
            TerminalPaneView(session: session)
        case .split(let splitNode):
            GeometryReader { geometry in
                splitBody(splitNode, in: geometry.size)
            }
        }
    }

    @ViewBuilder
    private func splitBody(_ split: PaneSplitNode, in size: CGSize) -> some View {
        let dividerThickness: CGFloat = 6
        let clampedFraction = split.clampedFraction

        if split.axis == .horizontal {
            // Horizontal split: left | right (HStack)
            let availableWidth = max(size.width - dividerThickness, 1)
            let firstWidth = max(120, availableWidth * clampedFraction)
            let secondWidth = max(120, availableWidth - firstWidth)

            HStack(spacing: 0) {
                SplitNodeView(sessionController: sessionController, node: split.first)
                    .frame(width: firstWidth)

                SplitDivider(
                    axis: .horizontal,
                    fraction: clampedFraction,
                    availableLength: availableWidth
                ) { fraction in
                    sessionController.updateSplitFraction(splitID: split.id, fraction: fraction)
                }

                SplitNodeView(sessionController: sessionController, node: split.second)
                    .frame(width: secondWidth)
            }
        } else {
            // Vertical split: top / bottom (VStack)
            let availableHeight = max(size.height - dividerThickness, 1)
            let firstHeight = max(90, availableHeight * clampedFraction)
            let secondHeight = max(90, availableHeight - firstHeight)

            VStack(spacing: 0) {
                SplitNodeView(sessionController: sessionController, node: split.first)
                    .frame(height: firstHeight)

                SplitDivider(
                    axis: .vertical,
                    fraction: clampedFraction,
                    availableLength: availableHeight
                ) { fraction in
                    sessionController.updateSplitFraction(splitID: split.id, fraction: fraction)
                }

                SplitNodeView(sessionController: sessionController, node: split.second)
                    .frame(height: secondHeight)
            }
        }
    }
}
