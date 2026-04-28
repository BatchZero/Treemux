//
//  WorkspaceTabKind.swift
//  Treemux

import Foundation

/// Discriminator for tab content. New kinds (e.g. logs, diffs) can be added
/// without breaking existing terminal-tab persistence.
enum WorkspaceTabKind: String, Codable {
    case terminal
    case fileBrowser
}
