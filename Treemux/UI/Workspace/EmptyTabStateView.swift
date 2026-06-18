//
//  EmptyTabStateView.swift
//  Treemux

import SwiftUI

/// Empty state shown when all tabs have been closed.
/// Displays an icon, message, and "New Terminal" button.
struct EmptyTabStateView: View {
    @EnvironmentObject private var theme: ThemeManager
    let onCreateTab: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("No open terminals")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button(action: onCreateTab) {
                Label("New Terminal", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle(accent: theme.accentColor, onAccent: theme.onAccentColor))
            .controlSize(.large)

            Text("⌘T to create a new tab")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
