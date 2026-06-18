//
//  DesignSystem.swift
//  Treemux
//
//  Fixed, theme-independent layout tokens from .claude/DESIGN.md.
//  Colors come from the YAML theme (ThemeManager); these do not.
//

import CoreGraphics

/// Spacing scale (DESIGN.md). Base unit 8; md=17 is the body line rhythm.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 17
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let section: CGFloat = 80
}

/// Corner-radius scale (DESIGN.md).
enum Radius {
    static let xs: CGFloat = 5
    static let sm: CGFloat = 8
    static let md: CGFloat = 11
    static let lg: CGFloat = 18
    static let pill: CGFloat = 9999
}
