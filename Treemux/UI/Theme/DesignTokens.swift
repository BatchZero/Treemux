//
//  DesignTokens.swift
//  Treemux
//
//  "Phosphor Instrument" design-system color tokens — the shared palette every
//  file-browser visual surface derives from. Tuned for the dark theme (the app's
//  primary appearance); light-theme variants are intentionally out of scope for
//  this foundation phase.
//

import SwiftUI

enum DesignTokens {

    /// Raw hex strings — the single source of truth (asserted in tests).
    enum Hex {
        static let ink = "#13161D"      // app base (blue-charcoal)
        static let panel = "#191D26"    // sidebar / tree / tab-bar background
        static let surface = "#232936"  // active tab, hover, selected row
        static let line = "#2C333F"     // hairlines, dividers, indent guides
        static let text = "#D7DCE4"
        static let muted = "#7C8694"
        static let faint = "#525B69"

        // Semantic accents
        static let shell = "#54D38B"    // terminal / shell (phosphor green)
        static let files = "#5BA6F2"    // files (azure)

        // Type-accent palette (mapped to file types in P1b's FileIconCatalog)
        static let accentOrange = "#E8865A"
        static let accentAmber = "#E2A55C"
        static let accentGreen = "#5FC98A"   // file-type icons only (e.g. config/data) — NOT the shell tab accent
        static let accentViolet = "#A98BFA"
    }

    static let ink = Color(hex: Hex.ink)
    static let panel = Color(hex: Hex.panel)
    static let surface = Color(hex: Hex.surface)
    static let line = Color(hex: Hex.line)
    static let text = Color(hex: Hex.text)
    static let muted = Color(hex: Hex.muted)
    static let faint = Color(hex: Hex.faint)

    static let shell = Color(hex: Hex.shell)
    static let files = Color(hex: Hex.files)

    static let accentOrange = Color(hex: Hex.accentOrange)
    static let accentAmber = Color(hex: Hex.accentAmber)
    static let accentGreen = Color(hex: Hex.accentGreen)
    static let accentViolet = Color(hex: Hex.accentViolet)

    /// Hex of the accent that identifies a workspace tab's kind (testable).
    static func tabAccentHex(for kind: WorkspaceTabKind) -> String {
        switch kind {
        case .fileBrowser: return Hex.files
        case .terminal: return Hex.shell
        }
    }

    /// The accent color that identifies a workspace tab's kind.
    static func tabAccent(for kind: WorkspaceTabKind) -> Color {
        switch kind {
        case .fileBrowser: return files
        case .terminal: return shell
        }
    }
}
