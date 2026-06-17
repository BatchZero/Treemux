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
      accent: "#418ADE"
      accentOnDark: "#2997FF"
      onAccent: "#FFFFFF"
      window: "#0F1114"
      sidebar: "#0F1114"
      pane: "#111317"
      paneHeader: "#151820"
      tabBar: "#0F1114"
      statusBar: "#0F1114"
      selection: "#1A2A42"
      selectionStroke: "#418ADE"
      hairline: "#FFFFFF1A"
      textPrimary: "#F0F0F2"
      textSecondary: "#C5C8C6"
      textMuted: "#7A7A7A"
      success: "#B5BD68"
      warning: "#F0C674"
      danger: "#CC6666"
    terminal:
      foreground: "#C5C8C6"
      background: "#111317"
      cursor: "#C5C8C6"
      cursorText: "#111317"
      selection: "#373B41"
      selectionText: "#C5C8C6"
      ansi:
        - "#1D1F21"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#C5C8C6"
        - "#969896"
        - "#CC6666"
        - "#B5BD68"
        - "#F0C674"
        - "#81A2BE"
        - "#B294BB"
        - "#8ABEB7"
        - "#FFFFFF"
    """

    static let lightYAML = """
    id: treemux-light
    name: Treemux Light
    author: BatchZero
    appearance: light
    ui:
      accent: "#0066CC"
      accentOnDark: "#2997FF"
      onAccent: "#FFFFFF"
      window: "#FFFFFF"
      sidebar: "#F5F5F7"
      pane: "#FFFFFF"
      paneHeader: "#FAFAFC"
      tabBar: "#F5F5F7"
      statusBar: "#F5F5F7"
      selection: "#D2E3FB"
      selectionStroke: "#0066CC"
      hairline: "#1D1D1F14"
      textPrimary: "#1D1D1F"
      textSecondary: "#333333"
      textMuted: "#7A7A7A"
      success: "#248A3D"
      warning: "#B25000"
      danger: "#D70015"
    terminal:
      foreground: "#1D1D1F"
      background: "#FFFFFF"
      cursor: "#0066CC"
      cursorText: "#FFFFFF"
      selection: "#D2E3FB"
      selectionText: "#1D1D1F"
      ansi:
        - "#1D1D1F"
        - "#D70015"
        - "#248A3D"
        - "#B25000"
        - "#0066CC"
        - "#8944AB"
        - "#0071A4"
        - "#6E6E73"
        - "#7A7A7A"
        - "#E5484D"
        - "#30A46C"
        - "#D9822B"
        - "#2997FF"
        - "#A450CF"
        - "#0091C2"
        - "#1D1D1F"
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
