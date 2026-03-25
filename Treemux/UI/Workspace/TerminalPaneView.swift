//
//  TerminalPaneView.swift
//  Treemux
//

import SwiftUI

/// Displays a single terminal pane with a compact header showing status,
/// title, and working directory, followed by the Ghostty terminal surface.
struct TerminalPaneView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var session: ShellSession

    var body: some View {
        VStack(spacing: 0) {
            // Pane header
            paneHeader

            // Terminal surface
            TerminalHostView(session: session, shouldRestoreFocus: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.dividerColor, lineWidth: 1)
        )
        .padding(2)
    }

    // MARK: - Pane header

    private var paneHeader: some View {
        HStack(spacing: 6) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            // Tmux badge
            if let tmuxSession = session.detectedTmuxSession {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 9))
                    Text("tmux: \(tmuxSession)")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.accentColor.opacity(0.12), in: Capsule())
            }

            Text(session.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            if let cwd = session.reportedWorkingDirectory {
                Text(abbreviatedPath(cwd))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.paneHeaderBackground)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch session.lifecycle {
        case .running:
            return .green
        case .starting:
            return .yellow
        case .exited:
            return .red
        case .idle:
            return .gray
        }
    }

    /// Abbreviates the home directory prefix to "~".
    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
