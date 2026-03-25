//
//  AppSettings.swift
//  Treemux
//

import Foundation

// MARK: - Application Settings

/// Top-level application settings persisted as JSON.
struct AppSettings: Codable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var aiTools: AIToolSettings = AIToolSettings()
}

/// Terminal emulator appearance and behavior settings.
struct TerminalSettings: Codable {
    var defaultShell: String = "/bin/zsh"
    var fontSize: Int = 14
    var cursorStyle: String = "block"
}

/// Settings controlling application startup behavior.
struct StartupSettings: Codable {
    var restoreLastSession: Bool = true
}

/// SSH connection configuration settings.
struct SSHSettings: Codable {
    var configPaths: [String] = ["~/.ssh/config"]
}

/// AI tool integration settings.
struct AIToolSettings: Codable {
    var autoDetect: Bool = true
}
