//
//  UnsavedQuitPrompt.swift
//  Treemux
//

import Foundation

/// Builds the aggregate "you have unsaved files" alert copy shown when quitting
/// the app. Split into a pure, locale-independent `plan(paths:)` (dedup + name
/// list + overflow count) and a thin `build(paths:)` that composes localized
/// strings from it.
enum UnsavedQuitPrompt {
    /// Maximum number of filenames listed before collapsing the rest into an
    /// "…and N more." line.
    static let maxListed = 5

    /// Locale-independent decomposition of the unsaved paths. `nil` when there
    /// is nothing unsaved (caller lets the quit proceed).
    struct Plan: Equatable {
        let uniqueCount: Int
        let listedNames: [String]
        let overflowCount: Int
    }

    static func plan(paths: [String]) -> Plan? {
        var seen = Set<String>()
        var unique: [String] = []
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        guard !unique.isEmpty else { return nil }
        let names = unique.map { URL(fileURLWithPath: $0).lastPathComponent }
        let listed = Array(names.prefix(maxListed))
        return Plan(
            uniqueCount: unique.count,
            listedNames: listed,
            overflowCount: unique.count - listed.count
        )
    }

    /// Localized `(message, informative)` for the alert, or `nil` when nothing
    /// is unsaved.
    static func build(paths: [String]) -> (message: String, informative: String)? {
        guard let plan = plan(paths: paths) else { return nil }
        let message = plan.uniqueCount == 1
            ? String(localized: "1 file has unsaved changes.")
            : String.localizedStringWithFormat(
                String(localized: "%d files have unsaved changes."), plan.uniqueCount)
        var lines = plan.listedNames
        if plan.overflowCount > 0 {
            lines.append(String.localizedStringWithFormat(
                String(localized: "…and %d more."), plan.overflowCount))
        }
        lines.append("")
        lines.append(String(localized: "Quitting now will discard these changes."))
        return (message, lines.joined(separator: "\n"))
    }
}
