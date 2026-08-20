//
//  SplitNodeView.swift
//  Treemux
//

import SwiftUI
import UniformTypeIdentifiers

private struct PaneDropTarget: Equatable {
    let paneID: UUID
    let zone: PaneDropZone
}

private enum PaneDragPasteboard {
    static let type = UTType(exportedAs: "com.batchzero.treemux.pane")
}

/// Renders a `SessionLayoutNode` tree and owns the shared pane-drag state.
struct SplitNodeView: View {
    let sessionController: WorkspaceSessionController
    let node: SessionLayoutNode
    var onClosePane: (UUID) -> Void

    @State private var draggedPaneID: UUID?
    @State private var dropTarget: PaneDropTarget?

    var body: some View {
        Group {
            if let zoomedID = sessionController.zoomedPaneID {
                let session = sessionController.ensureSession(for: zoomedID)
                TerminalPaneView(session: session, onClose: { onClosePane(zoomedID) })
            } else {
                SplitNodeBranchView(
                    sessionController: sessionController,
                    node: node,
                    onClosePane: onClosePane,
                    draggedPaneID: $draggedPaneID,
                    dropTarget: $dropTarget
                )
            }
        }
    }
}

/// Recursive branch renderer. Drag state is supplied by the root so every
/// pane participates in one canvas-wide drag session.
private struct SplitNodeBranchView: View {
    let sessionController: WorkspaceSessionController
    let node: SessionLayoutNode
    var onClosePane: (UUID) -> Void
    @Binding var draggedPaneID: UUID?
    @Binding var dropTarget: PaneDropTarget?

    @ViewBuilder
    var body: some View {
        switch node {
        case .pane(let leaf):
            PaneDropHostView(
                paneID: leaf.paneID,
                sessionController: sessionController,
                onClosePane: onClosePane,
                draggedPaneID: $draggedPaneID,
                dropTarget: $dropTarget
            )
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
            let availableWidth = max(size.width - dividerThickness, 1)
            let firstWidth = max(120, availableWidth * clampedFraction)
            let secondWidth = max(120, availableWidth - firstWidth)

            HStack(spacing: 0) {
                branch(for: split.first)
                    .frame(width: firstWidth)

                SplitDivider(
                    axis: .horizontal,
                    fraction: clampedFraction,
                    availableLength: availableWidth
                ) { fraction in
                    sessionController.updateSplitFraction(splitID: split.id, fraction: fraction)
                }

                branch(for: split.second)
                    .frame(width: secondWidth)
            }
        } else {
            let availableHeight = max(size.height - dividerThickness, 1)
            let firstHeight = max(90, availableHeight * clampedFraction)
            let secondHeight = max(90, availableHeight - firstHeight)

            VStack(spacing: 0) {
                branch(for: split.first)
                    .frame(height: firstHeight)

                SplitDivider(
                    axis: .vertical,
                    fraction: clampedFraction,
                    availableLength: availableHeight
                ) { fraction in
                    sessionController.updateSplitFraction(splitID: split.id, fraction: fraction)
                }

                branch(for: split.second)
                    .frame(height: secondHeight)
            }
        }
    }

    private func branch(for child: SessionLayoutNode) -> some View {
        SplitNodeBranchView(
            sessionController: sessionController,
            node: child,
            onClosePane: onClosePane,
            draggedPaneID: $draggedPaneID,
            dropTarget: $dropTarget
        )
    }
}

private struct PaneDropHostView: View {
    let paneID: UUID
    let sessionController: WorkspaceSessionController
    var onClosePane: (UUID) -> Void
    @Binding var draggedPaneID: UUID?
    @Binding var dropTarget: PaneDropTarget?

    var body: some View {
        GeometryReader { geometry in
            let session = sessionController.ensureSession(for: paneID)
            TerminalPaneView(
                session: session,
                onClose: { onClosePane(paneID) },
                onDrag: {
                    draggedPaneID = paneID
                    return NSItemProvider(
                        item: paneID.uuidString as NSString,
                        typeIdentifier: PaneDragPasteboard.type.identifier
                    )
                }
            )
            .onDrop(of: [PaneDragPasteboard.type], delegate: PaneDropDelegate(
                targetPaneID: paneID,
                targetSize: geometry.size,
                sessionController: sessionController,
                draggedPaneID: $draggedPaneID,
                dropTarget: $dropTarget
            ))
            .overlay {
                if let dropTarget, dropTarget.paneID == paneID {
                    PaneDropPreview(zone: dropTarget.zone)
                }
            }
        }
    }
}

private struct PaneDropDelegate: DropDelegate {
    let targetPaneID: UUID
    let targetSize: CGSize
    let sessionController: WorkspaceSessionController
    @Binding var draggedPaneID: UUID?
    @Binding var dropTarget: PaneDropTarget?

    func validateDrop(info _: DropInfo) -> Bool {
        guard let draggedPaneID else { return false }
        return draggedPaneID != targetPaneID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedPaneID, draggedPaneID != targetPaneID else {
            if dropTarget?.paneID == targetPaneID {
                dropTarget = nil
            }
            return nil
        }
        let zone = PaneDropZone.resolve(location: info.location, in: targetSize)
        let updatedTarget = PaneDropTarget(paneID: targetPaneID, zone: zone)
        if dropTarget != updatedTarget {
            dropTarget = updatedTarget
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        if dropTarget?.paneID == targetPaneID {
            dropTarget = nil
        }
    }

    func performDrop(info _: DropInfo) -> Bool {
        defer {
            draggedPaneID = nil
            dropTarget = nil
        }
        guard let draggedPaneID,
              draggedPaneID != targetPaneID,
              let dropTarget,
              dropTarget.paneID == targetPaneID else {
            return false
        }
        return sessionController.rearrangePane(
            draggedPaneID,
            relativeTo: targetPaneID,
            dropZone: dropTarget.zone
        )
    }
}

private struct PaneDropPreview: View {
    @Environment(ThemeManager.self) private var theme
    let zone: PaneDropZone

    var body: some View {
        GeometryReader { geometry in
            switch zone {
            case .center:
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(theme.accentColor.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(theme.accentColor, lineWidth: 2)
                    }
                    .padding(Spacing.xxs)
            case .left:
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.2))
                        .frame(width: geometry.size.width * 0.3)
                    Spacer(minLength: 0)
                }
            case .right:
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.2))
                        .frame(width: geometry.size.width * 0.3)
                }
            case .top:
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.2))
                        .frame(height: geometry.size.height * 0.3)
                    Spacer(minLength: 0)
                }
            case .bottom:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.2))
                        .frame(height: geometry.size.height * 0.3)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
