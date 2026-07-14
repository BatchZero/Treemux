//
//  FileTreeSearch.swift
//  Treemux

import Foundation

/// Pure helpers for the file-tree live filter. Operates only on the tree already
/// loaded in memory — never touches the data source.
enum FileTreeSearch {
    static func matches(_ name: String, query: String) -> Bool {
        name.range(of: query, options: [.caseInsensitive]) != nil
    }

    /// Returns the node paths to show (matches + their ancestor directories) and
    /// the ancestor directory paths to force-open, for a case-insensitive
    /// substring query over the loaded tree.
    static func filter(rootChildren: [FileNode],
                       childrenByPath: [String: [FileNode]],
                       query: String) -> (visible: Set<String>, expanded: Set<String>) {
        var visible: Set<String> = []
        var expanded: Set<String> = []

        // Returns true when the subtree rooted at `node` contains a match.
        func walk(_ node: FileNode) -> Bool {
            let selfMatch = matches(node.name, query: query)
            var descendantMatch = false
            if let kids = childrenByPath[node.path] {
                for kid in kids {
                    // Call walk for every child (side effects populate `visible`).
                    if walk(kid) { descendantMatch = true }
                }
            }
            if selfMatch || descendantMatch {
                visible.insert(node.path)
                if descendantMatch { expanded.insert(node.path) }
                return true
            }
            return false
        }

        for node in rootChildren { _ = walk(node) }
        return (visible, expanded)
    }
}
