//
//  SidebarInfoBadge.swift
//  Treemux
//

import SwiftUI

/// A reusable capsule-shaped badge for sidebar row metadata.
struct SidebarInfoBadge: View {
    enum Tone {
        case neutral
        case accent
        case success
        case subtleSuccess
        case warning
    }

    let text: String
    let tone: Tone

    private var foreground: Color {
        switch tone {
        case .neutral:
            return .secondary
        case .accent:
            return .accentColor
        case .success:
            return .green
        case .subtleSuccess:
            return .green.opacity(0.82)
        case .warning:
            return .orange
        }
    }

    private var background: Color {
        switch tone {
        case .subtleSuccess:
            return .green.opacity(0.08)
        default:
            return Color.gray.opacity(0.15)
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}
