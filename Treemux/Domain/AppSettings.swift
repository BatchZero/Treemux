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
}

/// Terminal emulator appearance and behavior settings.
struct TerminalSettings: Codable, Equatable {
    var defaultShell: String = "/bin/zsh"
    var fontSize: Int = 14
    var cursorStyle: String = "block"
}

/// Settings controlling application startup behavior.
struct StartupSettings: Codable, Equatable {
    var restoreLastSession: Bool = true
}

/// SSH connection configuration settings.
struct SSHSettings: Codable, Equatable {
    var configPaths: [String] = ["~/.ssh/config"]
}

