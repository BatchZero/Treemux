//
//  CommandPaletteView.swift
//  Treemux
//

import SwiftUI

// MARK: - Command Definition

/// A single command that can be executed from the command palette.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let action: () -> Void
}

// MARK: - Command Palette View

/// Fuzzy-search overlay for executing commands. Activated by ⌘⇧P.
struct CommandPaletteView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .foregroundStyle(theme.textMuted)
                    TextField(
                        String(localized: "Search commands…"),
                        text: $query
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($isSearchFocused)
                    .onSubmit { executeSelected() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()
                    .overlay(theme.dividerColor)

                // Results list
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let filtered = filteredCommands
                        if filtered.isEmpty {
                            Text(String(localized: "No matching commands"))
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                                CommandRow(
                                    command: command,
                                    isSelected: index == selectedIndex,
                                    theme: theme
                                )
                                .onTapGesture {
                                    selectedIndex = index
                                    executeSelected()
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.dividerColor, lineWidth: 1)
            )
            .frame(width: 520)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let count = filteredCommands.count
            if selectedIndex < count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Commands

    private var allCommands: [PaletteCommand] {
        [
            PaletteCommand(
                title: String(localized: "Split Horizontal"),
                subtitle: nil, icon: "rectangle.split.1x2",
                shortcut: "⌘D",
                action: {
                    if let sc = store.selectedWorkspace?.sessionController,
                       let focused = sc.focusedPaneID {
                        sc.splitPane(focused, axis: .horizontal)
                    }
                }
            ),
            PaletteCommand(
                title: String(localized: "Split Vertical"),
                subtitle: nil, icon: "rectangle.split.2x1",
                shortcut: "⌘⇧D",
                action: {
                    if let sc = store.selectedWorkspace?.sessionController,
                       let focused = sc.focusedPaneID {
                        sc.splitPane(focused, axis: .vertical)
                    }
                }
            ),
            PaletteCommand(
                title: String(localized: "Close Pane"),
                subtitle: nil, icon: "xmark.square",
                shortcut: "⌘W",
                action: {
                    if let sc = store.selectedWorkspace?.sessionController,
                       let focused = sc.focusedPaneID {
                        sc.closePane(focused)
                    }
                }
            ),
            PaletteCommand(
                title: String(localized: "Toggle Sidebar"),
                subtitle: nil, icon: "sidebar.leading",
                shortcut: "⌘B",
                action: {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        with: nil
                    )
                }
            ),
            PaletteCommand(
                title: String(localized: "New Claude Code Session"),
                subtitle: "claude", icon: "brain.head.profile",
                shortcut: "⌘⇧C",
                action: {}
            ),
            PaletteCommand(
                title: String(localized: "New Codex Session"),
                subtitle: "codex", icon: "wand.and.stars",
                shortcut: nil,
                action: {}
            ),
            PaletteCommand(
                title: String(localized: "Open Project..."),
                subtitle: nil, icon: "plus.circle",
                shortcut: nil,
                action: {}
            ),
        ]
    }

    private var filteredCommands: [PaletteCommand] {
        guard !query.isEmpty else { return allCommands }
        let lower = query.lowercased()
        return allCommands.filter { cmd in
            cmd.title.lowercased().contains(lower) ||
            (cmd.subtitle?.lowercased().contains(lower) ?? false)
        }
    }

    private func executeSelected() {
        let filtered = filteredCommands
        guard selectedIndex < filtered.count else { return }
        filtered[selectedIndex].action()
        isPresented = false
    }
}

// MARK: - Command Row

private struct CommandRow: View {
    let command: PaletteCommand
    let isSelected: Bool
    let theme: ThemeManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? theme.accentColor : theme.textSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textMuted)
                }
            }

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected ? theme.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
}
