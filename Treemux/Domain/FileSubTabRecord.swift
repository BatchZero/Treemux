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
    /// Per-file rendering mode. `nil` means "use the default for this file kind".
    /// Optional so legacy JSON without the key decodes to `nil` automatically.
    var viewMode: FileViewMode?

    init(id: UUID = UUID(), path: String, isPinned: Bool, viewMode: FileViewMode? = nil) {
        self.id = id
        self.path = path
        self.isPinned = isPinned
        self.viewMode = viewMode
    }
}
