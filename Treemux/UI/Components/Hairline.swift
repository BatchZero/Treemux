//
//  Hairline.swift
//  Treemux
//
//  1px theme-driven hairline replacing heavy Divider()/Rectangle separators.
//  DESIGN.md: hairlines replace heavy dividers; color from theme.dividerColor.
//

import SwiftUI

private struct HairlineModifier: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    let edge: Edge

    func body(content: Content) -> some View {
        content.overlay(alignment: alignment) {
            Rectangle()
                .fill(theme.dividerColor)
                .frame(
                    width: edge == .leading || edge == .trailing ? 1 : nil,
                    height: edge == .top || edge == .bottom ? 1 : nil
                )
        }
    }

    private var alignment: Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

extension View {
    /// Overlays a 1px theme hairline on the given edge.
    func hairline(_ edge: Edge) -> some View {
        modifier(HairlineModifier(edge: edge))
    }
}
