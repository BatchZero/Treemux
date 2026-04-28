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
    var selectedFilePath: String?
    var splitRatio: Double
    var expandedDirs: [String]
    var showsHiddenFiles: Bool

    init(
        rootPath: String,
        rootKind: FileBrowserRootKind,
        selectedFilePath: String? = nil,
        splitRatio: Double = 0.28,
        expandedDirs: [String] = [],
        showsHiddenFiles: Bool = false
    ) {
        self.rootPath = rootPath
        self.rootKind = rootKind
        self.selectedFilePath = selectedFilePath
        self.splitRatio = splitRatio
        self.expandedDirs = expandedDirs
        self.showsHiddenFiles = showsHiddenFiles
    }

    enum CodingKeys: String, CodingKey {
        case rootPath, rootKind, selectedFilePath, splitRatio, expandedDirs, showsHiddenFiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        rootKind = try c.decode(FileBrowserRootKind.self, forKey: .rootKind)
        selectedFilePath = try c.decodeIfPresent(String.self, forKey: .selectedFilePath)
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.28
        expandedDirs = try c.decodeIfPresent([String].self, forKey: .expandedDirs) ?? []
        showsHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? false
    }
}
