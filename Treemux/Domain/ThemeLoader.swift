//
//  ThemeLoader.swift
//  Treemux
//

import Foundation
import Yams

/// One failed theme file, surfaced in the settings UI.
struct ThemeLoadError: Equatable {
    let fileName: String
    let message: String
}

/// Result of scanning a themes directory.
struct ThemeLoadResult: Equatable {
    let themes: [Theme]
    let errors: [ThemeLoadError]
}

/// Loads and validates `.yaml`/`.yml` theme files from a directory.
enum ThemeLoader {
    static func load(from directory: URL, fileManager: FileManager = .default) -> ThemeLoadResult {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return ThemeLoadResult(themes: [], errors: [])
        }

        let files = entries
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = YAMLDecoder()
        var themes: [Theme] = []
        var errors: [ThemeLoadError] = []
        var seenIDs = Set<String>()

        for file in files {
            let name = file.lastPathComponent
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let theme = try decoder.decode(Theme.self, from: text)
                try theme.validate()
                if seenIDs.contains(theme.id) {
                    errors.append(ThemeLoadError(
                        fileName: name,
                        message: "duplicate theme id '\(theme.id)' — skipped"))
                    continue
                }
                seenIDs.insert(theme.id)
                themes.append(theme)
            } catch let validation as ThemeValidationError {
                errors.append(ThemeLoadError(fileName: name, message: describe(validation)))
            } catch {
                errors.append(ThemeLoadError(fileName: name, message: error.localizedDescription))
            }
        }

        themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ThemeLoadResult(themes: themes, errors: errors)
    }

    private static func describe(_ error: ThemeValidationError) -> String {
        switch error {
        case let .badHex(field, value):
            return "invalid hex color in \(field): '\(value)'"
        case let .wrongAnsiCount(count):
            return "terminal.ansi must have exactly 16 entries (found \(count))"
        }
    }
}
