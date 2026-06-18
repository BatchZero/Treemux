//
//  BuiltInThemes.swift
//  Treemux
//

import Foundation
import Yams

/// The two shipped themes. The YAML literals are the authoritative source;
/// they are written to the user's themes directory on first run and can be
/// restored after deletion/edit.
enum BuiltInThemes {

    static let ids = ["treemux-dark", "treemux-light"]

    static let fileNames: [String: String] = [
        "treemux-dark": "treemux-dark.yaml",
        "treemux-light": "treemux-light.yaml"
    ]

    static let darkYAML = """
    id: treemux-dark
    name: Treemux Dark
    author: BatchZero
    appearance: dark
    ui:
      accent: "#FFFFFF"
      accentOnDark: "#FFFFFF"
      onAccent: "#0A0A0A"
      window: "#0A0A0A"
      sidebar: "#0C0C0D"
      pane: "#0F0F10"
      paneHeader: "#141518"
      tabBar: "#0A0A0A"
      statusBar: "#0A0A0A"
      selection: "#1C1D20"
      selectionStroke: "#FFFFFF"
      hairline: "#FFFFFF14"
      textPrimary: "#F5F6F7"
      textSecondary: "#DADBDF"
      textMuted: "#7D8187"
      success: "#5FB87A"
      warning: "#FF7A17"
      danger: "#F2555A"
    terminal:
      foreground: "#DADBDF"
      background: "#0A0A0A"
      cursor: "#FFFFFF"
      cursorText: "#0A0A0A"
      selection: "#2A2C31"
      selectionText: "#FFFFFF"
      ansi:
        - "#0A0A0A"
        - "#FF6B5E"
        - "#9DBF8A"
        - "#E6A84D"
        - "#A0C3EC"
        - "#C4B5FD"
        - "#8FD0C4"
        - "#DADBDF"
        - "#5A5E63"
        - "#FF8A7E"
        - "#B4D3A4"
        - "#F0BE6B"
        - "#BBD4F2"
        - "#D6CBFE"
        - "#A8DDD3"
        - "#FFFFFF"
    """

    static let lightYAML = """
    id: treemux-light
    name: Treemux Light
    author: BatchZero
    appearance: light
    ui:
      accent: "#EA2804"
      accentOnDark: "#FF6A3D"
      onAccent: "#FFFFFF"
      window: "#F9F7F3"
      sidebar: "#F3F0E8"
      pane: "#FFFFFF"
      paneHeader: "#FAF8F3"
      tabBar: "#F3F0E8"
      statusBar: "#F3F0E8"
      selection: "#FBDDD3"
      selectionStroke: "#EA2804"
      hairline: "#20202014"
      textPrimary: "#202020"
      textSecondary: "#575757"
      textMuted: "#8D8D8D"
      success: "#2B9A66"
      warning: "#B5670A"
      danger: "#C01F00"
    terminal:
      foreground: "#202020"
      background: "#FCFAF6"
      cursor: "#EA2804"
      cursorText: "#FFFFFF"
      selection: "#FBDDD3"
      selectionText: "#202020"
      ansi:
        - "#202020"
        - "#EA2804"
        - "#2B9A66"
        - "#B5670A"
        - "#2563EB"
        - "#B5407F"
        - "#0E8A86"
        - "#575757"
        - "#8D8D8D"
        - "#FF5A30"
        - "#33B97B"
        - "#C2710A"
        - "#3B82F6"
        - "#C75BA0"
        - "#1FA39E"
        - "#202020"
    """

    private static func yaml(forID id: String) -> String {
        id == "treemux-light" ? lightYAML : darkYAML
    }

    /// Writes any missing built-in files without overwriting existing ones.
    static func ensureInstalled(in directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in ids {
            let url = directory.appendingPathComponent(fileNames[id]!)
            if !fileManager.fileExists(atPath: url.path) {
                try yaml(forID: id).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Force-rewrites both built-in files (overwriting edits/corruption).
    static func restore(in directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in ids {
            let url = directory.appendingPathComponent(fileNames[id]!)
            try yaml(forID: id).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// In-memory dark theme for when no valid theme exists on disk.
    static func fallbackDark() -> Theme {
        // The literal is validated by tests; force-try is safe here.
        // swiftlint:disable:next force_try
        try! YAMLDecoder().decode(Theme.self, from: darkYAML)
    }
}
