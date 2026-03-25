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
