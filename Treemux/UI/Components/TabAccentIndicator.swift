//
//  TabAccentIndicator.swift
//  Treemux
//
//  Flat 2px accent bar marking the selected tab. DESIGN.md: chrome carries no
//  shadow; the active-tab indicator is a solid accent bar. Color is supplied by
//  the caller (theme.accentColor); inactive tabs draw nothing.
//

import SwiftUI

struct TabAccentIndicator: ViewModifier {
    let color: Color
    let isActive: Bool
    var inset: CGFloat = Spacing.xs

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: 2)
                    .padding(.horizontal, inset)
            }
        }
    }
}

extension View {
    /// Applies the flat tab accent indicator when `active` is true.
    func tabAccentIndicator(_ color: Color, active: Bool, inset: CGFloat = Spacing.xs) -> some View {
        modifier(TabAccentIndicator(color: color, isActive: active, inset: inset))
    }
}

#Preview {
    HStack(spacing: 6) {
        Text("README.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .tabAccentIndicator(Color(hex: "#5BA6F2"), active: true)
        Text("zsh")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .tabAccentIndicator(Color(hex: "#5BA6F2"), active: true)
        Text("other.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .tabAccentIndicator(Color(hex: "#5BA6F2"), active: false)
    }
    .padding(24)
    .background(Color(hex: "#191D26"))
}
