//
//  FileBrowserTabState.swift
//  Treemux

import Foundation

enum FileBrowserRootKind: String, Codable {
    case project
    case worktree
}

/// Persistent state for a file browser tab. Edited buffers (dirty content)
/// are intentionally NOT persisted — they're discarded on restart after a
/// dirty-prompt confirmation; this prevents stale buffers from overwriting
/// files that were modified externally (in terminal, by `git pull`, etc.).
struct FileBrowserTabState: Codable, Equatable {
    var rootPath: String
    var rootKind: FileBrowserRootKind
    var splitRatio: Double
    var expandedDirs: [String]
    var showsHiddenFiles: Bool
    /// Sub-tabs (VSCode-style) opened within this outer tab. Stage D adds the
    /// data; D3+D4 add the controller state machine; E adds the UI.
    var subTabs: [FileSubTabRecord]
    /// Currently focused sub-tab. Nil when `subTabs` is empty.
    var activeSubTabID: UUID?

    init(
        rootPath: String,
        rootKind: FileBrowserRootKind,
        splitRatio: Double = 0.28,
        expandedDirs: [String] = [],
        showsHiddenFiles: Bool = false,
        subTabs: [FileSubTabRecord] = [],
        activeSubTabID: UUID? = nil
    ) {
        self.rootPath = rootPath
        self.rootKind = rootKind
        self.splitRatio = splitRatio
        self.expandedDirs = expandedDirs
        self.showsHiddenFiles = showsHiddenFiles
        self.subTabs = subTabs
        self.activeSubTabID = activeSubTabID
    }

    enum CodingKeys: String, CodingKey {
        case rootPath, rootKind
        case selectedFilePath           // legacy field; absent in new writes
        case splitRatio, expandedDirs, showsHiddenFiles
        case subTabs, activeSubTabID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        rootKind = try c.decode(FileBrowserRootKind.self, forKey: .rootKind)
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.28
        expandedDirs = try c.decodeIfPresent([String].self, forKey: .expandedDirs) ?? []
        showsHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false

        // Three decode shapes:
        //   1. New blob: `subTabs` (and optional `activeSubTabID`) present.
        //   2. Legacy blob: only `selectedFilePath` is present — synthesize a
        //      single pinned sub-tab so the user's previously-open file
        //      survives the upgrade.
        //   3. Neither: empty sub-tab list.
        if let new = try c.decodeIfPresent([FileSubTabRecord].self, forKey: .subTabs) {
            subTabs = new
            activeSubTabID = try c.decodeIfPresent(UUID.self, forKey: .activeSubTabID)
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .selectedFilePath) {
            let migrated = FileSubTabRecord(path: legacy, isPinned: true)
            subTabs = [migrated]
            activeSubTabID = migrated.id
        } else {
            subTabs = []
            activeSubTabID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        // Encoder NEVER writes `selectedFilePath`; new blobs carry only the
        // `subTabs` / `activeSubTabID` pair. The legacy field exists in
        // `CodingKeys` solely to give the decoder a key to read on upgrade.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(rootKind, forKey: .rootKind)
        try c.encode(splitRatio, forKey: .splitRatio)
        try c.encode(expandedDirs, forKey: .expandedDirs)
        try c.encode(showsHiddenFiles, forKey: .showsHiddenFiles)
        try c.encode(subTabs, forKey: .subTabs)
        try c.encodeIfPresent(activeSubTabID, forKey: .activeSubTabID)
    }
}
