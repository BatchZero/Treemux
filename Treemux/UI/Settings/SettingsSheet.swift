//
//  SettingsSheet.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Tabbed settings sheet covering all configuration areas.
struct SettingsSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    enum SettingsTab: String, CaseIterable {
        case general, terminal, theme, aiTools, ssh, shortcuts

        var label: String {
            switch self {
            case .general: return String(localized: "General")
            case .terminal: return String(localized: "Terminal")
            case .theme: return String(localized: "Theme")
            case .aiTools: return String(localized: "AI Tools")
            case .ssh: return "SSH"
            case .shortcuts: return String(localized: "Shortcuts")
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

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                settingsContent(for: tab)
                    .tabItem {
                        Label(tab.label, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .frame(width: 520, height: 380)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func settingsContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(settings: $store.settings)
        case .terminal:
            TerminalSettingsView(settings: $store.settings)
        case .theme:
            ThemeSettingsView(settings: $store.settings, themeManager: theme)
        case .aiTools:
            AIToolsSettingsView(settings: $store.settings)
        case .ssh:
            SSHSettingsView(settings: $store.settings)
        case .shortcuts:
            ShortcutsSettingsView()
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

            Picker(String(localized: "Appearance"), selection: $settings.appearance) {
                Text(String(localized: "Follow System")).tag("system")
                Text(String(localized: "Dark")).tag("dark")
                Text(String(localized: "Light")).tag("light")
            }
            .onChange(of: settings.appearance) { _, newValue in
                let appearance: NSAppearance? = switch newValue {
                case "dark": NSAppearance(named: .darkAqua)
                case "light": NSAppearance(named: .aqua)
                default: nil
                }
                NSApp.keyWindow?.appearance = appearance
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
    private let shortcuts: [(String, String)] = [
        ("⌘T", "New Tab"),
        ("⌘W", "Close Pane"),
        ("⌘D", "Split Horizontal"),
        ("⌘⇧D", "Split Vertical"),
        ("⌘[ / ⌘]", "Switch Panes"),
        ("⌘⇧Enter", "Zoom Pane"),
        ("⌘⇧P", "Command Palette"),
        ("⌘B", "Toggle Sidebar"),
        ("⌘K", "Quick Switch Project"),
        ("⌘⇧T", "Theme Switch"),
        ("⌘⇧C", "New Claude Code"),
        ("⌘,", "Settings"),
    ]

    var body: some View {
        Form {
            Section(String(localized: "Keyboard Shortcuts")) {
                ForEach(shortcuts, id: \.0) { shortcut, action in
                    HStack {
                        Text(action)
                        Spacer()
                        Text(shortcut)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
