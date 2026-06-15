//
//  EditorHighlightPolicy.swift
//  Treemux
//
//  Pure decision for whether the editor should run tree-sitter highlighting on
//  a buffer. Extracted from the view so the size/language gate is unit-testable
//  and so the render path never performs a filesystem stat.
//

import Foundation

enum EditorHighlightPolicy {
    /// Files larger than this open without tree-sitter highlighting. Kept in
    /// bytes; callers pass the in-memory buffer size (`content.utf8.count`),
    /// never an on-disk `stat`.
    static let highlightSizeLimit: Int = 2 * 1024 * 1024

    /// Highlight only when the path maps to a known language AND the in-memory
    /// buffer is within the size limit.
    static func shouldHighlight(path: String, byteCount: Int) -> Bool {
        guard FileTypeClassifier.language(forPath: path) != nil else { return false }
        return byteCount <= highlightSizeLimit
    }
}
