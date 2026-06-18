//
//  DesignFonts.swift
//  Treemux
//
//  Typography roles: a monospaced data layer (file names, tab titles, tree rows,
//  eyebrow labels) reusing the terminal's feel; chrome (menus, settings, dialogs)
//  on SF Pro.
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

extension DesignFonts {
    // MARK: - Chrome semantic roles (SF Pro, IDE-scaled)
    //
    // DESIGN.md's 56/40px marketing display sizes don't apply to IDE chrome.
    // Titles keep the SF Pro tight-tracking signature; body/caption land at
    // macOS-standard 13/11 so dialogs read as native, not oversized.

    /// Dialog / toolbar title — the only place DESIGN.md tight tracking applies.
    /// SwiftUI Font has no letterSpacing; apply `.tracking(dialogTitleTracking)`
    /// on the title Text.
    static let dialogTitle: Font = chrome(size: 20, weight: .semibold)
    static let dialogTitleTracking: CGFloat = -0.4

    /// Section / group heading inside dialogs and the sidebar.
    static let sectionTitle: Font = chrome(size: 13, weight: .semibold)
    /// Default chrome body copy.
    static let chromeBody: Font = chrome(size: 13, weight: .regular)
    /// Emphasized small chrome label (file-name header, etc.).
    static let chromeStrong: Font = chrome(size: 11, weight: .semibold)
    /// Secondary chrome caption.
    static let chromeCaption: Font = chrome(size: 11, weight: .regular)

    // MARK: - Data layer semantic role (mono)

    /// Tab-group eyebrow ("Files"/"Shell") — small mono label.
    static let eyebrow: Font = dataLayer(size: 9, weight: .semibold)
}
