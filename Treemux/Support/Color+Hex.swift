//
//  Color+Hex.swift
//  Treemux
//

import SwiftUI

extension Color {
    /// Initialize a Color from a hex string (e.g. "#FF0000" or "#FF000080" with alpha).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgba: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgba)

        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            r = Double((rgba >> 16) & 0xFF) / 255.0
            g = Double((rgba >> 8) & 0xFF) / 255.0
            b = Double(rgba & 0xFF) / 255.0
            a = 1.0
        case 8:
            r = Double((rgba >> 24) & 0xFF) / 255.0
            g = Double((rgba >> 16) & 0xFF) / 255.0
            b = Double((rgba >> 8) & 0xFF) / 255.0
            a = Double(rgba & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 1.0
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
