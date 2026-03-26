//
//  SettingsSheet.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Sidebar-based settings sheet following macOS System Settings pattern.
struct SettingsSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AppSettings()
    @State private var originalSettings = AppSettings()

    private var hasChanges: Bool {
        draft != originalSettings
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, terminal, theme, aiTools, ssh, shortcuts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return String(localized: "General")
            case .terminal: return String(localized: "Terminal")
            case .theme: return String(localized: "Theme")
            case .aiTools: return String(localized: "AI Tools")
            case .ssh: return "SSH"
            case .shortcuts: return String(localized: "Shortcuts")
            }
        }

        var subtitle: String {
            switch self {
            case .general: return String(localized: "Language and startup behavior")
            case .terminal: return String(localized: "Shell, font, and cursor settings")
            case .theme: return String(localized: "Color themes and appearance")
            case .aiTools: return String(localized: "AI agent detection and presets")
            case .ssh: return String(localized: "SSH config file paths")
            case .shortcuts: return String(localized: "Customize keyboard shortcuts")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .terminal: return "apple.terminal"
            case .theme: return "paintbrush"
            case .aiTools: return "brain.head.profile"
            case .ssh: return "network"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            // Detail
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.title)
                        .font(.system(size: 20, weight: .semibold))
                    Text(selection.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                Divider()

                // Content
                ScrollView {
                    settingsContent(for: selection)
                        .padding(4)
                }

                // Footer with Save / Cancel
                Divider()
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) {
                        // Revert theme if it was changed during preview
                        if draft.activeThemeID != originalSettings.activeThemeID {
                            theme.setActiveTheme(originalSettings.activeThemeID)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(String(localized: "Save")) {
                        store.updateSettings(draft)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 460)
        .task {
            draft = store.settings
            originalSettings = store.settings
        }
    }

    // MARK: - Section Content

    @ViewBuilder
    private func settingsContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(settings: $draft)
        case .terminal:
            TerminalSettingsView(settings: $draft)
        case .theme:
            ThemeSettingsView(settings: $draft, themeManager: theme)
        case .aiTools:
            AIToolsSettingsView(settings: $draft)
        case .ssh:
            SSHSettingsView(settings: $draft)
        case .shortcuts:
            ShortcutsSettingsView(settings: $draft)
        }
    }
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Picker(String(localized: "Language"), selection: $settings.language) {
                Text(String(localized: "Follow System")).tag("system")
                Text("English").tag("en")
                Text("中文").tag("zh-Hans")
            }

            Picker(String(localized: "On Startup"), selection: $settings.startup.restoreLastSession) {
                Text(String(localized: "Restore Last Session")).tag(true)
                Text(String(localized: "Blank Window")).tag(false)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Terminal Settings

private struct TerminalSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            TextField(String(localized: "Default Shell"), text: $settings.terminal.defaultShell)

            Stepper(
                value: $settings.terminal.fontSize, in: 8...32
            ) {
                HStack {
                    Text(String(localized: "Font Size"))
                    Spacer()
                    Text("\(settings.terminal.fontSize)")
                        .foregroundStyle(.secondary)
                }
            }

            Picker(String(localized: "Cursor Style"), selection: $settings.terminal.cursorStyle) {
                Text(String(localized: "Block")).tag("block")
                Text(String(localized: "Bar")).tag("bar")
                Text(String(localized: "Underline")).tag("underline")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Theme Settings

private struct ThemeSettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var themeManager: ThemeManager

    var body: some View {
        Form {
            Picker(String(localized: "Active Theme"), selection: $settings.activeThemeID) {
                ForEach(themeManager.availableThemes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .onChange(of: settings.activeThemeID) { _, newID in
                themeManager.setActiveTheme(newID)
            }

            Section {
                Text(String(localized: "Place custom theme JSON files in ~/.treemux/themes/"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Tools Settings

private struct AIToolsSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Toggle(String(localized: "Auto-detect AI Tools"), isOn: $settings.aiTools.autoDetect)

            Section {
                Text(String(localized: "Place agent preset JSON files in ~/.treemux/agents/"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - SSH Settings

private struct SSHSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section(String(localized: "SSH Config Paths")) {
                ForEach(settings.ssh.configPaths.indices, id: \.self) { index in
                    TextField("Path", text: $settings.ssh.configPaths[index])
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts Settings

private struct ShortcutsSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            ForEach(ShortcutCategory.allCases.filter { cat in
                ShortcutAction.allCases.contains { $0.category == cat }
            }) { category in
                Section(category.title) {
                    let actions = ShortcutAction.allCases.filter { $0.category == category }
                    ForEach(actions) { action in
                        ShortcutRow(action: action, settings: $settings)
                    }
                }
            }

            Section {
                Button(String(localized: "Reset All to Defaults")) {
                    TreemuxKeyboardShortcuts.resetAll(in: &settings)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var settings: AppSettings

    private var state: ShortcutState {
        TreemuxKeyboardShortcuts.state(for: action, in: settings)
    }

    private var effectiveShortcut: StoredShortcut? {
        TreemuxKeyboardShortcuts.effectiveShortcut(for: action, in: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 13))
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ShortcutRecorderButton(
                    shortcut: Binding(
                        get: { effectiveShortcut },
                        set: { newShortcut in
                            if let shortcut = newShortcut {
                                TreemuxKeyboardShortcuts.setShortcut(shortcut, for: action, in: &settings)
                            }
                        }
                    ),
                    emptyTitle: String(localized: "Not Set")
                )
                .frame(width: 120)
            }

            HStack(spacing: 8) {
                if state == .custom {
                    Button(String(localized: "Reset")) {
                        TreemuxKeyboardShortcuts.resetShortcut(for: action, in: &settings)
                    }
                    .font(.system(size: 11))
                }

                if state != .disabled {
                    Button(String(localized: "Disable")) {
                        TreemuxKeyboardShortcuts.disableShortcut(for: action, in: &settings)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 2)
    }
}
