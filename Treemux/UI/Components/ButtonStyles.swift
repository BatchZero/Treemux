//
//  ButtonStyles.swift
//  Treemux
//
//  The two DESIGN.md button grammars. Colors are injected at the call site
//  (from ThemeManager) because ButtonStyle can't read @EnvironmentObject.
//

import SwiftUI

/// Primary call-to-action: full-pill accent fill, press shrinks to 0.95.
/// Use ONLY for the single primary action in a dialog (Save/Open/Connect).
struct PillButtonStyle: ButtonStyle {
    let accent: Color
    let onAccent: Color

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(onAccent)
            .padding(.vertical, 11)
            .padding(.horizontal, 22)
            .background(accent, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Compact utility action: Radius.sm. Bordered by default; pass `fill` to render
/// an equal-sized filled primary (fill background + `onFill` text) so a primary
/// action can sit next to a Cancel at the same dimensions.
/// `isActive` (or press) lifts the bordered tint to `activeTint` (accent).
/// Disabled buttons dim to 0.4 and skip the press scale.
struct UtilityButtonStyle: ButtonStyle {
    let tint: Color
    let activeTint: Color
    let border: Color
    var isActive: Bool = false
    var fill: Color? = nil
    var onFill: Color = .white

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(foreground(isPressed: configuration.isPressed))
            .padding(.vertical, 8)
            .padding(.horizontal, 15)
            .background {
                if let fill {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(fill)
                } else {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private func foreground(isPressed: Bool) -> Color {
        if fill != nil { return onFill }
        return isActive || isPressed ? activeTint : tint
    }
}
