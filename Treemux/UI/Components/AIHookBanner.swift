//
//  AIHookBanner.swift
//  Treemux
//

import SwiftUI

/// Compact one-time banner inviting the user to install AI agent hooks for the
/// detected agent in the current workspace. Shown above the tab bar by
/// `WorkspaceTabContainerView`. The banner exposes three actions:
/// preview-and-install, dismiss-for-session, and don't-ask-for-this-host.
struct AIHookBanner: View {
    let displayName: String
    let configPath: String
    let onPreview: () -> Void
    let onSkip: () -> Void
    let onSkipHost: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text("Treemux can show when \(displayName) finishes or needs your input")
                    .font(.system(size: 12, weight: .semibold))
                Text("by adding a hook to \(configPath).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button("Preview & Install") { onPreview() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                Button("Not Now") { onSkip() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                Button("Don't ask for this host") { onSkipHost() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    }
}
