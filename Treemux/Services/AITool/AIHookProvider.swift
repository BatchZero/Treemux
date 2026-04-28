//
//  AIHookProvider.swift
//  Treemux
//

import Foundation

/// One AI agent's view of "where do I live and what does my hook config look like".
/// Implementations are stateless; they take an `AIHookFileSystem` to operate on.
protocol AIHookProvider {
    var kind: AIToolKind { get }
    var displayName: String { get }
    /// File paths whose existence (any-of) indicates the user has used this agent.
    var detectionPaths: [String] { get }
    /// Path of the primary config file we'd merge into.
    var configFile: String { get }
    /// Helper resource filenames that this provider needs (relative to the app
    /// bundle's `Resources/AIHooks/`).
    var helperResources: [String] { get }
    /// Current schema version we install.
    var version: String { get }

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus
    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt
    func uninstall(fs: AIHookFileSystem) async throws
}

/// Built-in registry. Future agents are added here.
enum AIHookProviderRegistry {
    static func providers() -> [AIHookProvider] {
        [
            ClaudeCodeHookProvider(),
            CodexHookProvider(),
            OpencodeHookProvider(),
        ]
    }
}
