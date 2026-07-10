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

/// Per-file parsed-theme cache keyed by absolute path. An entry is reused
/// when both mtime and byte size match, skipping read + YAML decode for
/// unchanged files on reloads (import/delete/reset rescans).
/// Confinement: held by @MainActor ThemeManager; not thread-safe by design.
final class ThemeFileCache {
    private struct Entry {
        let modificationDate: Date
        let fileSize: Int
        let theme: Theme
    }
    private var entries: [String: Entry] = [:]
    #if DEBUG
    private(set) var hitCount = 0
    #endif

    func cachedTheme(forPath path: String, modificationDate: Date, fileSize: Int) -> Theme? {
        guard let e = entries[path],
              e.modificationDate == modificationDate,
              e.fileSize == fileSize else { return nil }
        #if DEBUG
        hitCount += 1
        #endif
        return e.theme
    }

    func store(theme: Theme, forPath path: String, modificationDate: Date, fileSize: Int) {
        entries[path] = Entry(modificationDate: modificationDate, fileSize: fileSize, theme: theme)
    }
}

/// Loads and validates `.yaml`/`.yml` theme files from a directory.
enum ThemeLoader {
    static func load(
        from directory: URL,
        fileManager: FileManager = .default,
        cache: ThemeFileCache? = nil
    ) -> ThemeLoadResult {
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

        func appendDedupingByID(_ theme: Theme, fileName: String) {
            if seenIDs.contains(theme.id) {
                errors.append(ThemeLoadError(
                    fileName: fileName,
                    message: "duplicate theme id '\(theme.id)' — skipped"))
                return
            }
            seenIDs.insert(theme.id)
            themes.append(theme)
        }

        for file in files {
            let name = file.lastPathComponent
            let attrs = try? fileManager.attributesOfItem(atPath: file.path)
            let mtime = attrs?[.modificationDate] as? Date
            let size = attrs?[.size] as? Int
            if let cache, let mtime, let size,
               let cached = cache.cachedTheme(forPath: file.path, modificationDate: mtime, fileSize: size) {
                appendDedupingByID(cached, fileName: name)
                continue
            }
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let theme = try decoder.decode(Theme.self, from: text)
                try theme.validate()
                if let cache, let mtime, let size {
                    cache.store(theme: theme, forPath: file.path, modificationDate: mtime, fileSize: size)
                }
                appendDedupingByID(theme, fileName: name)
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
        case let .badAppearance(value):
            return "appearance must be 'dark' or 'light' (found '\(value)')"
        }
    }
}
