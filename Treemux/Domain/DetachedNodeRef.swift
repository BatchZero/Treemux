//
//  DetachedNodeRef.swift
//  Treemux

import Foundation
import CommonCrypto

/// Identifies a sidebar node that has been detached into its own window.
/// Persisted in `workspace-state.json` so child windows can be rebuilt on launch.
enum DetachedNodeRef: Hashable, Codable {
    /// A whole workspace torn off into its own window.
    case workspace(UUID)
    /// A single worktree torn off; parent workspace stays in the main sidebar.
    case worktree(workspaceID: UUID, worktreeID: UUID)
    /// An entire remote server section torn off.
    case remoteGroup(String)

    /// A stable, filesystem-safe suffix identifying this detached node in an
    /// autosave/window-state key. Two distinct refs must produce distinct
    /// suffixes so each torn-off window persists to its own key; the suffix is
    /// deterministic so the same ref resolves to the same key across launches.
    ///
    /// Encoding the value (rather than relying on `String(reflecting:)`) keeps
    /// the suffix immune to Swift ABI/description changes, and a short SHA-256
    /// digest guards against collisions even when associated values contain
    /// arbitrary characters (e.g. remote-group names with pipes or slashes).
    var autosaveKeySuffix: String {
        let payload: String
        switch self {
        case .workspace(let id):
            payload = "workspace:\(id.uuidString)"
        case .worktree(let workspaceID, let worktreeID):
            payload = "worktree:\(workspaceID.uuidString):\(worktreeID.uuidString)"
        case .remoteGroup(let name):
            payload = "remoteGroup:\(name)"
        }

        // Prefix the readable discriminator so the suffix stays human-inspectable
        // while the digest guarantees uniqueness.
        let digest = Self.sha256Hex(payload).prefix(16)
        return "\(payload.replacingOccurrences(of: ":", with: "_"))-\(digest)"
    }

    /// Returns the lowercase hex SHA-256 digest of `string` (UTF-8 encoded).
    private static func sha256Hex(_ string: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        string.withCString { ptr in
            CC_SHA256(ptr, CC_LONG(strlen(ptr)), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
