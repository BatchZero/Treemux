//
//  SidebarItemIconView.swift
//  Treemux
//

import SwiftUI

// MARK: - Activity Indicator State

/// Two-state activity indicator for sidebar icons.
enum SidebarIconActivityIndicator {
    case none
    case working   // Static dot — terminal sessions are running
}

// MARK: - Icon View

/// Renders a sidebar icon as a rounded-rectangle (or circular) tile with an SF Symbol
/// and an optional activity dot at the bottom-right corner.
struct SidebarItemIconView: View {
    let icon: SidebarItemIcon
    let size: CGFloat
    var usesCircularShape: Bool = false
    var activityIndicator: SidebarIconActivityIndicator = .none
    var activityPalette: SidebarIconPalette = .amber
    var isEmphasized: Bool = false

    private var palette: SidebarIconPaletteDescriptor {
        icon.palette.descriptor
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(
            cornerRadius: usesCircularShape ? size / 2 : max(7, size * 0.34),
            style: .continuous
        )
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

            if activityIndicator == .working {
                SidebarIconActivityBadge(size: size, palette: activityPalette)
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

// MARK: - Activity Badge

/// Static dot shown at the bottom-right of a sidebar icon when the node has
/// at least one running terminal session.
struct SidebarIconActivityBadge: View {
    @EnvironmentObject private var theme: ThemeManager
    let size: CGFloat
    let palette: SidebarIconPalette

    private var activityColor: Color {
        palette.descriptor.gradientEnd
    }

    private var badgeSize: CGFloat {
        max(6, size * 0.28)
    }

    var body: some View {
        Circle()
            .fill(activityColor)
            .frame(width: badgeSize, height: badgeSize)
            .overlay(Circle().stroke(theme.sidebarBackground, lineWidth: 1))
    }
}
