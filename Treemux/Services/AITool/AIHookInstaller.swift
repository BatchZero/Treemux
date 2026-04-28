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

/// Coordinates hook inspection and installation across providers and targets.
/// All operations dispatch to the appropriate `AIHookProvider` for a given
/// `AIToolKind` and `AIHookFileSystem`.
@MainActor
final class AIHookInstaller {
    private let providers: [AIHookProvider]
    private let bundle: Bundle

    init(providers: [AIHookProvider] = AIHookProviderRegistry.providers(),
         bundle: Bundle = .main) {
        self.providers = providers
        self.bundle = bundle
    }

    /// Bundle URL pointing to the directory containing helper resources
    /// (`notify.sh`, `notify-codex.sh`, `treemux-notify.js`). Returns nil
    /// if the resource folder is missing (e.g., misconfigured build).
    var helperBundleURL: URL? {
        bundle.resourceURL?.appendingPathComponent("AIHooks", isDirectory: true)
    }

    /// Look up the provider for a kind. Nil if the kind has no registered provider.
    func provider(for kind: AIToolKind) -> AIHookProvider? {
        providers.first { $0.kind == kind }
    }

    /// Inspect a single agent's hook status. Returns `.unknown(reason:)` if no
    /// provider is registered for the kind.
    func inspect(_ kind: AIToolKind, fs: AIHookFileSystem) async throws -> HookStatus {
        guard let p = provider(for: kind) else {
            return .unknown(reason: "No provider registered for \(kind)")
        }
        return try await p.inspect(fs: fs)
    }

    /// Inspect every registered provider against a target's filesystem. Returns
    /// pairs of (provider, status). Errors are wrapped as `.unknown(reason:)`
    /// per-provider so a single failure doesn't kill the whole inspection.
    func inspectAll(fs: AIHookFileSystem) async -> [(AIHookProvider, HookStatus)] {
        var results: [(AIHookProvider, HookStatus)] = []
        for p in providers {
            let status: HookStatus
            do {
                status = try await p.inspect(fs: fs)
            } catch {
                status = .unknown(reason: error.localizedDescription)
            }
            results.append((p, status))
        }
        return results
    }

    /// Install a single agent's hook. Throws `HookInstallError.unsupported` if
    /// no provider is registered, or `HookInstallError.ioError` if the helper
    /// bundle is missing.
    @discardableResult
    func install(_ kind: AIToolKind, fs: AIHookFileSystem) async throws -> HookInstallReceipt {
        guard let p = provider(for: kind) else {
            throw HookInstallError.unsupported("Unknown agent kind: \(kind)")
        }
        guard let url = helperBundleURL else {
            throw HookInstallError.ioError("Helper bundle missing: AIHooks/ not found in app Resources")
        }
        return try await p.install(fs: fs, helperBundleURL: url)
    }

    /// Uninstall a single agent's hook. No-op if no provider for the kind.
    func uninstall(_ kind: AIToolKind, fs: AIHookFileSystem) async throws {
        guard let p = provider(for: kind) else { return }
        try await p.uninstall(fs: fs)
    }
}
