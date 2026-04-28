//
//  AppSettings.swift
//  Treemux
//

import Foundation

// MARK: - Application Settings

/// Top-level application settings persisted as JSON.
struct AppSettings: Codable, Equatable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var appearance: String = "system"  // "system", "dark", "light"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var shortcutOverrides: [String: ShortcutOverride] = [:]
    var defaultLocalTerminalIcon: SidebarItemIcon = .localTerminalDefault
    var updates: UpdateSettings = UpdateSettings()
    /// Controls whether the built-in `~` terminal workspace appears in the sidebar.
    /// True by default. When false and at least one other workspace exists, `~` is filtered out.
    /// When false and no other workspace exists, the filter is overridden as a fallback so the sidebar is never empty.
    var showDefaultTerminal: Bool = true

    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance, terminal, startup, ssh,
             shortcutOverrides, defaultLocalTerminalIcon, updates, showDefaultTerminal
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "system"
        activeThemeID = try container.decodeIfPresent(String.self, forKey: .activeThemeID) ?? "treemux-dark"
        appearance = try container.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        terminal = try container.decodeIfPresent(TerminalSettings.self, forKey: .terminal) ?? TerminalSettings()
        startup = try container.decodeIfPresent(StartupSettings.self, forKey: .startup) ?? StartupSettings()
        ssh = try container.decodeIfPresent(SSHSettings.self, forKey: .ssh) ?? SSHSettings()
        shortcutOverrides = try container.decodeIfPresent([String: ShortcutOverride].self, forKey: .shortcutOverrides) ?? [:]
        defaultLocalTerminalIcon = try container.decodeIfPresent(SidebarItemIcon.self, forKey: .defaultLocalTerminalIcon) ?? .localTerminalDefault
        updates = try container.decodeIfPresent(UpdateSettings.self, forKey: .updates) ?? UpdateSettings()
        showDefaultTerminal = try container.decodeIfPresent(Bool.self, forKey: .showDefaultTerminal) ?? true
    }
}

/// Terminal emulator appearance and behavior settings.
struct TerminalSettings: Codable, Equatable {
    var defaultShell: String = "/bin/zsh"
    var fontSize: Int = 14
    var cursorStyle: String = "bar"
}

/// Settings controlling application startup behavior.
struct StartupSettings: Codable, Equatable {
    var restoreLastSession: Bool = true
}

/// SSH connection configuration settings.
struct SSHSettings: Codable, Equatable {
    var configPaths: [String] = ["~/.ssh/config"]
}

/// Software update preferences.
struct UpdateSettings: Codable, Equatable {
    var automaticallyChecksForUpdates: Bool = true
    var automaticallyDownloadsUpdates: Bool = false
}

