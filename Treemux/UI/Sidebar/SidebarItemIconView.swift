//
//  SidebarItemIconView.swift
//  Treemux
//

import SwiftUI

/// Renders a sidebar icon as a rounded-rectangle tile with an SF Symbol.
struct SidebarItemIconView: View {
    let icon: SidebarItemIcon
    let size: CGFloat
    var isActive: Bool = false

    private var palette: SidebarIconPaletteDescriptor {
        icon.palette.descriptor
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: max(7, size * 0.34), style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon.symbolName)
                .font(.system(size: max(9, size * 0.48), weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay(
                    backgroundShape
                        .strokeBorder(palette.border, lineWidth: 1)
                )

            if isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: max(6, size * 0.28), height: max(6, size * 0.28))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }

    @ViewBuilder
    private var background: some View {
        switch icon.fillStyle {
        case .solid:
            backgroundShape.fill(palette.solidBackground)
        case .gradient:
            backgroundShape.fill(
                LinearGradient(
                    colors: [palette.gradientStart, palette.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }
}
