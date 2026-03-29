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
