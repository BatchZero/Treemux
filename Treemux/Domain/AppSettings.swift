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
}

/// Terminal emulator appearance and behavior settings.
///
/// Note: the user-facing font size is expressed as `fontSizeOffset` — an
/// integer relative to a hidden base. The actual point size used by Ghostty
/// is computed at render time from the active display's PPI via
/// `AdaptiveFontSizeCalculator`. The legacy `fontSize` JSON key is migrated to
/// `fontSizeOffset` on first decode and never re-encoded.
struct TerminalSettings: Equatable {
    var defaultShell: String
    var fontSizeOffset: Int
    var cursorStyle: String

    init(
        defaultShell: String = "/bin/zsh",
        fontSizeOffset: Int = 0,
        cursorStyle: String = "bar"
    ) {
        self.defaultShell = defaultShell
        self.fontSizeOffset = TerminalSettings.clamp(fontSizeOffset)
        self.cursorStyle = cursorStyle
    }

    static func clamp(_ value: Int) -> Int {
        min(
            max(value, AdaptiveFontSizeCalculator.offsetRange.lowerBound),
            AdaptiveFontSizeCalculator.offsetRange.upperBound
        )
    }
}

extension TerminalSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case defaultShell
        case fontSizeOffset
        case cursorStyle
        case fontSize  // legacy, decode-only
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shell = try container.decodeIfPresent(String.self, forKey: .defaultShell) ?? "/bin/zsh"
        let cursor = try container.decodeIfPresent(String.self, forKey: .cursorStyle) ?? "bar"

        let offset: Int
        if let stored = try container.decodeIfPresent(Int.self, forKey: .fontSizeOffset) {
            offset = stored
        } else if let legacy = try container.decodeIfPresent(Int.self, forKey: .fontSize) {
            offset = legacy - 14
        } else {
            offset = 0
        }
        self.init(defaultShell: shell, fontSizeOffset: offset, cursorStyle: cursor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultShell, forKey: .defaultShell)
        try container.encode(fontSizeOffset, forKey: .fontSizeOffset)
        try container.encode(cursorStyle, forKey: .cursorStyle)
    }
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

