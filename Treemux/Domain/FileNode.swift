//
//  FileNode.swift
//  Treemux

import Foundation

/// One entry in a file browser directory listing. Trees are loaded lazily —
/// `children` is nil for unexpanded directories, and `[]` for empty / loaded.
struct FileNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case directory
        case file
        case symlink(target: String?)
    }

    let id: String       // absolute path doubles as id
    let name: String
    let path: String
    let kind: Kind
    let sizeBytes: Int64?
    let modifiedAt: Date?

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }
}

/// Metadata fetched before deciding how to render a file (size guard, type).
struct FileMetadata: Equatable {
    let path: String
    let sizeBytes: Int64
    let modifiedAt: Date?
    let isDirectory: Bool
    let isSymbolicLink: Bool
}
