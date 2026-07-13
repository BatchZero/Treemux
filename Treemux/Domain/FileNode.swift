//
//  FileNode.swift
//  Treemux

import Foundation

/// One entry in a file browser directory listing. Trees are loaded lazily —
/// `children` is nil for unexpanded directories, and `[]` for empty / loaded.
struct FileNode: Identifiable, Equatable, Codable, Sendable {
    enum Kind: Equatable, Codable, Sendable {
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
    /// Only meaningful when `kind` is `.symlink`: true when the link resolves to
    /// a directory, so the tree can render it as expandable. Defaults to false so
    /// existing constructions and legacy cached snapshots stay valid.
    var symlinkTargetIsDirectory: Bool = false

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var isSymlink: Bool {
        if case .symlink = kind { return true }
        return false
    }

    /// A real directory, or a symlink whose target is a directory. Drives the
    /// disclosure triangle and expand routing in the file tree.
    var isExpandableDirectory: Bool {
        isDirectory || (isSymlink && symlinkTargetIsDirectory)
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }

    // Custom decode so snapshots written before `symlinkTargetIsDirectory`
    // existed still load (the synthesized decoder would throw on the missing
    // key). Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, sizeBytes, modifiedAt, symlinkTargetIsDirectory
    }

    init(id: String, name: String, path: String, kind: Kind,
         sizeBytes: Int64?, modifiedAt: Date?, symlinkTargetIsDirectory: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.symlinkTargetIsDirectory = symlinkTargetIsDirectory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(Kind.self, forKey: .kind)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        symlinkTargetIsDirectory = try c.decodeIfPresent(Bool.self, forKey: .symlinkTargetIsDirectory) ?? false
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
