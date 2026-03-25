//
//  PathFormatting.swift
//  Treemux
//

import Foundation

extension String {
    /// Returns the path with the home directory abbreviated to ~.
    nonisolated var abbreviatedPath: String {
        let home = NSHomeDirectory()
        if hasPrefix(home) {
            return "~" + dropFirst(home.count)
        }
        return self
    }

    /// Returns the last path component of the string treated as a file path.
    nonisolated var lastPathComponentValue: String {
        URL(fileURLWithPath: self).lastPathComponent
    }

    /// Returns a shell-safe single-quoted version of the string.
    nonisolated var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
