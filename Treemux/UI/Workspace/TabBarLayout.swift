//
//  TabBarLayout.swift
//  Treemux
//

import SwiftUI

/// Browser-style equal-width tab sizing and the measurement preference keys the
/// tab bars use to feed it. Pure so the width math is unit-testable.
enum TabBarLayout {
    /// Smallest a tab may shrink to before the bar overflows into horizontal scroll.
    static let minTabWidth: CGFloat = 64
    /// Largest a tab grows to when there is spare room (Chrome-style cap).
    static let maxTabWidth: CGFloat = 240

    /// The width every tab in a bar should take so `tabCount` tabs divide the
    /// space left after the bar's fixed chrome, clamped to a readable range.
    /// `tabCount == 0` returns `maxWidth` (no division); a negative usable width
    /// clamps up to `minWidth`.
    static func uniformWidth(
        viewport: CGFloat,
        tabCount: Int,
        reservedChrome: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        guard tabCount > 0 else { return maxWidth }
        let usable = viewport - reservedChrome
        let raw = usable / CGFloat(tabCount)
        return min(max(raw, minWidth), maxWidth)
    }
}

/// Sums the widths of a bar's fixed chrome elements (group eyebrows, dividers)
/// so tabs can divide only the remaining space.
struct TabBarChromeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// Reports the natural width of a bar's tab content (the inner HStack) so the
/// bar can compute how far it can scroll horizontally.
struct TabBarContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the scroll viewport width of a tab bar.
struct TabBarViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
