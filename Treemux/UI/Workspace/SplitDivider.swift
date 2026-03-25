//
//  SplitDivider.swift
//  Treemux
//

import SwiftUI

/// A draggable divider between two panes in a split layout.
/// Supports both horizontal and vertical orientations with drag-to-resize.
struct SplitDivider: View {
    let axis: SplitAxis
    let fraction: Double
    let availableLength: CGFloat
    let onUpdate: (Double) -> Void

    @State private var dragStartFraction: Double?

    private let thickness: CGFloat = 6

    var body: some View {
        ZStack {
            // Hit target area (transparent, wider than visible divider)
            Rectangle()
                .fill(Color.clear)

            // Visible divider handle
            Capsule(style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(
                    width: axis == .horizontal ? 4 : 44,
                    height: axis == .vertical ? 4 : 44
                )

            // Inner accent line
            Capsule(style: .continuous)
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: axis == .horizontal ? 2 : 16,
                    height: axis == .vertical ? 2 : 16
                )
        }
        .frame(
            width: axis == .horizontal ? thickness : nil,
            height: axis == .vertical ? thickness : nil
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let startFraction = dragStartFraction ?? fraction
                    if dragStartFraction == nil {
                        dragStartFraction = fraction
                    }
                    let delta = axis == .horizontal
                        ? value.translation.width / max(availableLength, 1)
                        : value.translation.height / max(availableLength, 1)
                    onUpdate(startFraction + delta)
                }
                .onEnded { _ in
                    dragStartFraction = nil
                }
        )
    }
}
