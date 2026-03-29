//
//  EmptyTabStateView.swift
//  Treemux

import SwiftUI

/// Empty state shown when all tabs have been closed.
/// Displays an icon, message, and "New Terminal" button.
struct EmptyTabStateView: View {
    let onCreateTab: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No open terminals"))
                .font(.title3)
                .foregroundStyle(.secondary)

            Button(action: onCreateTab) {
                Label(String(localized: "New Terminal"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(String(localized: "⌘T to create a new tab"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
