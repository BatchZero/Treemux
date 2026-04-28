//
//  OpencodeHookProvider.swift
//  Treemux
//

import Foundation

/// AIHookProvider implementation for opencode (~/.config/opencode/).
///
/// Unlike Claude (JSON merge) and Codex (TOML marker block), opencode supports
/// fully self-contained plugin files dropped into `~/.config/opencode/plugins/`.
/// We own the whole `treemux-notify.js` file: install writes it, uninstall
/// removes it, and there is no merging to worry about.
struct OpencodeHookProvider: AIHookProvider {
    var kind: AIToolKind { .opencode }
    var displayName: String { "opencode" }
    var detectionPaths: [String] { ["~/.config/opencode/config.json", "~/.config/opencode"] }
    var configFile: String { "~/.config/opencode/plugins/treemux-notify.js" }
    var helperResources: [String] { ["notify.sh", "treemux-notify.js"] }
    var version: String { "1" }

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus {
        var detected = false
        for p in detectionPaths {
            if try await fs.exists(p) { detected = true; break }
        }
        guard detected else { return .notDetected }

        guard try await fs.exists(configFile) else { return .detectedNotInstalled }

        let helperOK = try await fs.exists("~/.treemux/hooks/notify.sh")
        if helperOK {
            return .installed(version: version, installedAt: Date())
        }
        return .tampered(reason: "Shared helper script missing at ~/.treemux/hooks/notify.sh")
    }

    /// Compute the planned file changes (plugin + helper) without writing.
    /// The first entry is always the plugin file (which equals `configFile`);
    /// the second entry is the shared `notify.sh` helper.
    private func computeChanges(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> [HookInstallChange] {
        var changes: [HookInstallChange] = []

        // 1) Plugin file (configFile).
        let pluginContent: String
        do {
            pluginContent = try String(
                contentsOf: helperBundleURL.appendingPathComponent("treemux-notify.js"),
                encoding: .utf8
            )
        } catch {
            throw HookInstallError.ioError("Cannot read bundled treemux-notify.js: \(error.localizedDescription)")
        }
        let currentPlugin = try await fs.readText(configFile)
        changes.append(HookInstallChange(
            path: configFile,
            proposed: pluginContent,
            current: currentPlugin
        ))

        // 2) Shared notify.sh helper.
        let helperContent: String
        do {
            helperContent = try String(
                contentsOf: helperBundleURL.appendingPathComponent("notify.sh"),
                encoding: .utf8
            )
        } catch {
            throw HookInstallError.ioError("Cannot read bundled notify.sh: \(error.localizedDescription)")
        }
        let currentHelper = try await fs.readText("~/.treemux/hooks/notify.sh")
        changes.append(HookInstallChange(
            path: "~/.treemux/hooks/notify.sh",
            proposed: helperContent,
            current: currentHelper
        ))

        return changes
    }

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        let changes = try await computeChanges(fs: fs, helperBundleURL: helperBundleURL)

        // Apply. Helper first (needs directory + chmod), then plugin.
        try await fs.makeDirectory("~/.treemux/hooks")
        // changes[1] is the helper, changes[0] is the plugin.
        try await fs.writeText(changes[1].path, changes[1].proposed)
        try await fs.makeExecutable(changes[1].path)
        try await fs.makeDirectory("~/.config/opencode/plugins")
        try await fs.writeText(changes[0].path, changes[0].proposed)

        return HookInstallReceipt(version: version, installedAt: Date())
    }

    func dryRunInstall(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> [HookInstallChange] {
        try await computeChanges(fs: fs, helperBundleURL: helperBundleURL)
    }

    func uninstall(fs: AIHookFileSystem) async throws {
        try await fs.removeFile(configFile)
        // Note: do NOT remove ~/.treemux/hooks/notify.sh — shared with Claude/Codex.
    }
}
