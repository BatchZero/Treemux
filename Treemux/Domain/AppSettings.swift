//
//  AppSettings.swift
//  Treemux
//

import Foundation
import CoreGraphics

// MARK: - File-Tree Density

/// File-tree row sizing density. Pure value type so the size maps are unit-testable.
enum TreeDensity: String, Codable, CaseIterable, Identifiable, Equatable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    /// Row height in points.
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 28
        case .comfortable: return 32
        case .spacious: return 38
        }
    }

    /// File-name font size in points.
    var fontSize: CGFloat {
        switch self {
        case .compact: return 12
        case .comfortable: return 13
        case .spacious: return 15
        }
    }
}

/// File-browser appearance settings. Distinct from the top-level
/// `AppSettings.appearance` (system/dark/light) selector.
struct FileTreeSettings: Codable, Equatable {
    var density: TreeDensity = .comfortable
}

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

    /// Whether the editor shows a word-completion popover while typing.
    /// Backed by `BufferWordIndex` (Tier 3a per the P1 design doc); LSP-based
    /// completion is deferred to P2.
    var enableCodeCompletion: Bool = true

    /// File-browser tree appearance (row density). See `FileTreeSettings`.
    var fileTree: FileTreeSettings = FileTreeSettings()

    enum CodingKeys: String, CodingKey {
        case version, language, activeThemeID, appearance, terminal, startup, ssh,
             shortcutOverrides, defaultLocalTerminalIcon, updates, showDefaultTerminal,
             enableCodeCompletion, fileTree
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
        enableCodeCompletion = try container.decodeIfPresent(Bool.self, forKey: .enableCodeCompletion) ?? true
        fileTree = try container.decodeIfPresent(FileTreeSettings.self, forKey: .fileTree) ?? FileTreeSettings()
    }
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
    /// User-facing terminal font offset. Always within
    /// `AdaptiveFontSizeCalculator.offsetRange` (-8 ... +12); enforced on
    /// construction and on every Codable decode.
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

    /// Clamps a candidate offset into the valid range. Delegates to the
    /// calculator so the bounds have a single source of truth.
    static func clamp(_ value: Int) -> Int {
        AdaptiveFontSizeCalculator.clampOffset(value)
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

