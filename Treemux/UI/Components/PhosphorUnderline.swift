//
//  PhosphorUnderline.swift
//  Treemux
//
//  The "Phosphor Instrument" signature: a glowing accent underline marking the
//  selected tab. Color is supplied by the caller (e.g. theme.accentColor);
//  inactive tabs draw nothing. Reuses the existing CodeEdit-style bottom stripe.
//

import SwiftUI

struct PhosphorUnderline: ViewModifier {
    let color: Color
    let isActive: Bool
    var inset: CGFloat = 8

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: 2)
                    .shadow(color: color.opacity(0.8), radius: 4)
                    .padding(.horizontal, inset)
            }
        }
    }
}

extension View {
    /// Applies the phosphor underline signature when `active` is true.
    func phosphorUnderline(_ color: Color, active: Bool, inset: CGFloat = 8) -> some View {
        modifier(PhosphorUnderline(color: color, isActive: active, inset: inset))
    }
}

#Preview {
    HStack(spacing: 6) {
        Text("README.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .phosphorUnderline(Color(hex: "#5BA6F2"), active: true)
        Text("zsh")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .phosphorUnderline(Color(hex: "#54D38B"), active: true)
        Text("other.md")
            .font(DesignFonts.dataLayer(size: 12.5))
            .padding(8)
            .background(Color(hex: "#232936"))
            .phosphorUnderline(Color(hex: "#5BA6F2"), active: false)
    }
    .padding(24)
    .background(Color(hex: "#191D26"))
}
