//
//  FileNode.swift
//  Treemux

import Foundation

/// The result of following a symbolic link far enough to decide whether it can
/// be expanded safely in the file tree.
enum SymlinkTargetResolution: Equatable, Codable, Sendable {
    case directory(canonicalIdentity: String)
    case file
    case broken
    case inaccessible
    case unresolved(reason: String?)
}

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
    /// Only meaningful when `kind` is `.symlink`.
    let symlinkTargetResolution: SymlinkTargetResolution

    var symlinkTargetIsDirectory: Bool {
        if case .directory = symlinkTargetResolution { return true }
        return false
    }

    var canonicalDirectoryIdentity: String? {
        guard case .directory(let identity) = symlinkTargetResolution else { return nil }
        return identity
    }

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

    // Custom coding keeps snapshots written before rich symlink resolution
    // metadata readable. A legacy Boolean cannot provide the canonical identity
    // needed for cycle checks, so it intentionally migrates to unresolved.
    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, sizeBytes, modifiedAt
        case symlinkTargetResolution, symlinkTargetIsDirectory
    }

    init(id: String, name: String, path: String, kind: Kind,
         sizeBytes: Int64?, modifiedAt: Date?, symlinkTargetIsDirectory: Bool = false,
         symlinkTargetResolution: SymlinkTargetResolution? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        if let symlinkTargetResolution {
            self.symlinkTargetResolution = symlinkTargetResolution
        } else if symlinkTargetIsDirectory {
            // Compatibility for existing in-memory constructors. Persisted
            // legacy values never take this path because they lack a safe ID.
            self.symlinkTargetResolution = .directory(canonicalIdentity: path)
        } else {
            self.symlinkTargetResolution = .unresolved(reason: nil)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(Kind.self, forKey: .kind)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        symlinkTargetResolution = try c.decodeIfPresent(
            SymlinkTargetResolution.self,
            forKey: .symlinkTargetResolution
        ) ?? .unresolved(reason: nil)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try c.encode(symlinkTargetResolution, forKey: .symlinkTargetResolution)
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
