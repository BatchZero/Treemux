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

    /// Whether the sidebar/tab AI attention indicator is enabled. Default: on.
    var aiActivityHintsEnabled: Bool = true

    /// Persisted set of (workspace, agent) pairs the user has dismissed via
    /// "Don't ask for this host". Stored as `["<workspaceID>:<AIToolKind.rawValue>"]`.
    var aiHookSkippedKeys: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance
        case terminal, startup, ssh, shortcutOverrides
        case defaultLocalTerminalIcon, updates
        case aiActivityHintsEnabled, aiHookSkippedKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "system"
        self.activeThemeID = try c.decodeIfPresent(String.self, forKey: .activeThemeID) ?? "treemux-dark"
        self.appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        self.terminal = try c.decodeIfPresent(TerminalSettings.self, forKey: .terminal) ?? TerminalSettings()
        self.startup = try c.decodeIfPresent(StartupSettings.self, forKey: .startup) ?? StartupSettings()
        self.ssh = try c.decodeIfPresent(SSHSettings.self, forKey: .ssh) ?? SSHSettings()
        self.shortcutOverrides = try c.decodeIfPresent([String: ShortcutOverride].self, forKey: .shortcutOverrides) ?? [:]
        self.defaultLocalTerminalIcon = try c.decodeIfPresent(SidebarItemIcon.self, forKey: .defaultLocalTerminalIcon) ?? .localTerminalDefault
        self.updates = try c.decodeIfPresent(UpdateSettings.self, forKey: .updates) ?? UpdateSettings()
        self.aiActivityHintsEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiActivityHintsEnabled) ?? true
        self.aiHookSkippedKeys = try c.decodeIfPresent([String].self, forKey: .aiHookSkippedKeys) ?? []
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

