//
//  FileSubTabRecord.swift
//  Treemux

import Foundation

/// One sub-tab inside a file-browser outer tab. Holds the path of the file
/// shown in the editor pane. `isPinned` is wired up by D3+D4 (state machine);
/// for now the legacy migration synthesizes a single pinned record so that
/// the previously-selected file survives upgrade.
struct FileSubTabRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var isPinned: Bool

    init(id: UUID = UUID(), path: String, isPinned: Bool) {
        self.id = id
        self.path = path
        self.isPinned = isPinned
    }
}
