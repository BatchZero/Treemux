//
//  HookDiff.swift
//  Treemux
//

import Foundation

enum DiffMark: Equatable {
    case unchanged
    case removed
    case added
}

struct DiffLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let mark: DiffMark
}

enum HookDiff {
    /// Compute line-level diff between `current` and `proposed`.
    /// `before` contains only `.unchanged` and `.removed` lines.
    /// `after`  contains only `.unchanged` and `.added` lines.
    /// When `current == nil`, before is a single placeholder
    /// `(file does not exist)` line and after is all `.added`.
    static func compute(current: String?, proposed: String) -> (before: [DiffLine], after: [DiffLine]) {
        let oldLines = current.map { splitLines($0) } ?? []
        let newLines = splitLines(proposed)

        if current == nil {
            let placeholder = [DiffLine(
                id: 0,
                text: String(localized: "(file does not exist)"),
                mark: .unchanged
            )]
            let after = newLines.enumerated().map { DiffLine(id: $0.offset, text: $0.element, mark: .added) }
            return (placeholder, after)
        }

        let diff = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        let before = oldLines.enumerated().map { idx, text in
            DiffLine(id: idx, text: text, mark: removedOffsets.contains(idx) ? .removed : .unchanged)
        }
        let after = newLines.enumerated().map { idx, text in
            DiffLine(id: idx, text: text, mark: insertedOffsets.contains(idx) ? .added : .unchanged)
        }
        return (before, after)
    }

    private static func splitLines(_ s: String) -> [String] {
        let normalized = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
