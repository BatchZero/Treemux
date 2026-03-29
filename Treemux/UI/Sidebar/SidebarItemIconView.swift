//
//  SidebarItemIconView.swift
//  Treemux
//

import SwiftUI

// MARK: - Activity Indicator State

/// Three-state activity indicator for sidebar icons.
enum SidebarIconActivityIndicator {
    case none
    case current   // Static dot — this worktree is the active working directory
    case working   // Animated pulse — terminal sessions are running
}

// MARK: - Icon View

/// Renders a sidebar icon as a rounded-rectangle (or circular) tile with an SF Symbol
/// and an optional activity indicator badge at the bottom-right corner.
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

            if activityIndicator != .none {
                SidebarIconActivityBadge(
                    kind: activityIndicator,
                    size: size,
                    palette: activityPalette,
                    isEmphasized: isEmphasized
                )
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

/// Animated or static badge shown at the bottom-right of a sidebar icon.
struct SidebarIconActivityBadge: View {
    let kind: SidebarIconActivityIndicator
    let size: CGFloat
    let palette: SidebarIconPalette
    let isEmphasized: Bool
    @State private var isAnimating = false

    private var activityColor: Color {
        palette.descriptor.gradientEnd
    }

    private var badgeSize: CGFloat {
        switch kind {
        case .working:
            return max(7, size * 0.34)
        case .current, .none:
            return max(6, size * 0.28)
        }
    }

    private var pulseLineWidth: CGFloat {
        isEmphasized ? 1.4 : 1.15
    }

    private var pulseOpacity: Double {
        isEmphasized ? 0.8 : 0.5
    }

    private var pulseScale: CGFloat {
        isEmphasized ? 2.15 : 1.85
    }

    private var pulseDuration: Double {
        isEmphasized ? 0.95 : 1.15
    }

    private var coreScale: CGFloat {
        guard kind == .working else { return 1 }
        return isAnimating ? 1.18 : 0.9
    }

    private var coreOpacity: Double {
        guard kind == .working else { return 1 }
        return isAnimating ? 1 : 0.82
    }

    private var glowRadius: CGFloat {
        guard kind == .working else { return 0 }
        return isEmphasized ? 6 : 4
    }

    var body: some View {
        ZStack {
            if kind == .working {
                Circle()
                    .fill(activityColor.opacity(isAnimating ? 0.18 : 0.06))
                    .frame(width: badgeSize, height: badgeSize)
                    .scaleEffect(isAnimating ? pulseScale * 0.9 : 1.0)
                    .blur(radius: isEmphasized ? 1.2 : 0.8)

                Circle()
                    .stroke(activityColor.opacity(pulseOpacity), lineWidth: pulseLineWidth)
                    .frame(width: badgeSize, height: badgeSize)
                    .scaleEffect(isAnimating ? pulseScale : 1.0)
                    .opacity(isAnimating ? 0 : pulseOpacity)
            }

            Circle()
                .fill(activityColor)
                .frame(width: badgeSize, height: badgeSize)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                .scaleEffect(coreScale)
                .opacity(coreOpacity)
                .shadow(color: activityColor.opacity(kind == .working ? 0.9 : 0), radius: glowRadius)
        }
        .onAppear {
            updateAnimationState()
        }
        .onChange(of: kind) { _, _ in
            updateAnimationState()
        }
    }

    private func updateAnimationState() {
        guard kind == .working else {
            isAnimating = false
            return
        }
        isAnimating = false
        withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
}
