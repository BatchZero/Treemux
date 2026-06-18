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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(onAccent)
            .padding(.vertical, 11)
            .padding(.horizontal, 22)
            .background(accent, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Compact utility action: Radius.sm, transparent fill, hairline border.
/// `isActive` (or press) lifts the tint to `activeTint` (accent).
/// Use for toolbar buttons, secondary actions, and Cancel.
struct UtilityButtonStyle: ButtonStyle {
    let tint: Color
    let activeTint: Color
    let border: Color
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(isActive || configuration.isPressed ? activeTint : tint)
            .padding(.vertical, 8)
            .padding(.horizontal, 15)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
