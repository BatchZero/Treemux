//
//  AIHookInstaller.swift
//  Treemux
//

import Foundation

/// Where a hook should be installed: the user's local home, or a remote SSH host.
enum HookTarget: Equatable {
    case local
    case remote(SSHTarget)

    /// Stable identity used in persistence keys and UI grouping.
    var id: String {
        switch self {
        case .local: return "local"
        case .remote(let t): return "remote:\(t.host)"
        }
    }
}

/// Result of inspecting whether a hook is installed for a given provider+target.
enum HookStatus: Equatable {
    case notDetected
    case detectedNotInstalled
    case installed(version: String, installedAt: Date)
    case installedOutdated(currentVersion: String, latestVersion: String)
    case tampered(reason: String)
    case unknown(reason: String)
}

/// Receipt produced by a successful install.
struct HookInstallReceipt: Equatable {
    let version: String
    let installedAt: Date
}

/// Errors thrown by the installer.
enum HookInstallError: LocalizedError {
    case userConfigConflict(String)
    case ioError(String)
    case parseError(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .userConfigConflict(let m): return m
        case .ioError(let m):           return m
        case .parseError(let m):        return m
        case .unsupported(let m):       return m
        }
    }
}
