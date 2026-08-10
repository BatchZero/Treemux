//
//  TerminalPaneView.swift
//  Treemux
//

import SwiftUI

enum TerminalReconnectControlState: Equatable {
    case enabled
    case reconnecting
    case failed

    static func resolve(isReconnecting: Bool, reconnectError: String?) -> Self {
        if reconnectError != nil { return .failed }
        if isReconnecting { return .reconnecting }
        return .enabled
    }
}

/// Displays a single terminal pane with a compact header showing status,
/// title, and working directory, followed by the Ghostty terminal surface.
struct TerminalPaneView: View {
    @Environment(ThemeManager.self) private var theme
    let session: ShellSession
    var onClose: () -> Void
    @State private var isCloseHovered = false
    @State private var isReconnectHovered = false
    @State private var showsReconnectConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Pane header
            paneHeader

            if session.reconnectError != nil {
                reconnectFailureBar
            }

            // Terminal surface
            TerminalHostView(session: session, shouldRestoreFocus: true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.dividerColor, lineWidth: 1)
        )
        .padding(2)
        .confirmationDialog(
            "Reconnect this pane?",
            isPresented: $showsReconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reconnect", role: .destructive) {
                session.reconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reconnect the terminal in this pane. The current foreground process will stop. Programs running in tmux will stay alive and Treemux will reattach when possible.")
        }
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

            Button {
                showsReconnectConfirmation = true
            } label: {
                Group {
                    if session.isReconnecting {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .foregroundStyle(isReconnectHovered ? theme.accentColor : theme.textSecondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(isReconnectHovered ? theme.dividerColor : .clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(session.isReconnecting)
            .onHover { hovering in
                isReconnectHovered = hovering
            }
            .help("Reconnect Pane")
            .accessibilityLabel("Reconnect Pane")

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isCloseHovered ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? theme.dividerColor : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCloseHovered = hovering
            }
            .help("Close Pane")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.paneHeaderBackground)
    }

    private var reconnectFailureBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.dangerColor)
            Text(session.reconnectError ?? "")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Button("Retry") {
                session.retryReconnect()
            }
            Button("Start Shell") {
                session.startShellAfterReconnectFailure()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.paneHeaderBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)
        }
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
