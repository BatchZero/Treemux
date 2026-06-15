//
//  SSHTarget.swift
//  Treemux
//

import Foundation

// MARK: - SSH connection target

struct SSHTarget: Codable, Hashable {
    let host: String
    let port: Int
    let user: String?
    let identityFile: String?
    let displayName: String
    let remotePath: String?
}

// MARK: - Editable SSH models

/// Mutable draft used by the shared edit sheet. Empty `user` / `identityFile`
/// mean the directive is not written. `port == 22` is treated as the default
/// and omitted on write.
struct SSHServerDraft: Equatable, Hashable {
    var alias: String
    var hostName: String
    var port: Int = 22
    var user: String = ""
    var identityFile: String = ""
}

/// A host entry surfaced in the management list, tagged with its source file.
/// `isEditable` is false for wildcard (`Host *`) or multi-pattern (`Host a b`)
/// blocks — those are shown read-only and only editable via raw editing.
struct ManagedSSHEntry: Identifiable, Hashable {
    let id: String          // "<sourcePath>::<alias>"
    let draft: SSHServerDraft
    let sourcePath: String  // expanded absolute path of the config file
    let isEditable: Bool
}
