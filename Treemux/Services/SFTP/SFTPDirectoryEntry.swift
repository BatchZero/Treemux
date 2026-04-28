//
//  SFTPDirectoryEntry.swift
//  Treemux
//

import Foundation

/// Represents a single directory entry from a remote SFTP listing.
struct SFTPDirectoryEntry: Identifiable, Comparable, Hashable {
    let id = UUID()
    let name: String
    let path: String

    static func < (lhs: SFTPDirectoryEntry, rhs: SFTPDirectoryEntry) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // Exclude id from hashing/equality (it's auto-generated)
    static func == (lhs: SFTPDirectoryEntry, rhs: SFTPDirectoryEntry) -> Bool {
        lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

// MARK: - Rich entry / stat types (file browser)

/// A rich directory listing entry — covers files, directories, and symlinks.
/// Used by the file browser feature when it needs more than just the directory tree.
struct SFTPRichEntry: Equatable {
    enum Kind: Equatable {
        case directory
        case file
        case symlink(target: String?)
    }

    let name: String
    let path: String
    let kind: Kind
    let sizeBytes: Int64?
    let modifiedAt: Date?
}

/// Result of a stat() call on a single remote path.
struct SFTPRichStat: Equatable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let sizeBytes: Int64
    let modifiedAt: Date?
}
