//
//  String+Helpers.swift
//  Treemux
//

import Foundation

extension String {
    /// Returns nil if the string is empty or contains only whitespace.
    nonisolated var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the string if non-empty, otherwise the fallback value.
    nonisolated func nonEmptyOrFallback(_ fallback: @autoclosure () -> String) -> String {
        nilIfEmpty ?? fallback()
    }
}
