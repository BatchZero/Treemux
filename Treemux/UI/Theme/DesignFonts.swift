//
//  DesignFonts.swift
//  Treemux
//
//  Typography roles for the "Phosphor Instrument" language. The data layer
//  (file names, tab titles, tree rows, eyebrow labels) is monospaced — reusing
//  the terminal's monospaced feel; chrome (menus, settings, dialogs) stays on
//  the system font.
//

import SwiftUI

enum DesignFonts {
    /// Monospaced font for the data layer.
    static func dataLayer(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// System font for chrome.
    static func chrome(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
