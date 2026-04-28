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

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        // Shared notify.sh
        let helperContent: String
        do {
            helperContent = try String(
                contentsOf: helperBundleURL.appendingPathComponent("notify.sh"),
                encoding: .utf8
            )
        } catch {
            throw HookInstallError.ioError("Cannot read bundled notify.sh: \(error.localizedDescription)")
        }
        try await fs.makeDirectory("~/.treemux/hooks")
        try await fs.writeText("~/.treemux/hooks/notify.sh", helperContent)
        try await fs.makeExecutable("~/.treemux/hooks/notify.sh")

        // Plugin
        let pluginContent: String
        do {
            pluginContent = try String(
                contentsOf: helperBundleURL.appendingPathComponent("treemux-notify.js"),
                encoding: .utf8
            )
        } catch {
            throw HookInstallError.ioError("Cannot read bundled treemux-notify.js: \(error.localizedDescription)")
        }
        try await fs.makeDirectory("~/.config/opencode/plugins")
        try await fs.writeText(configFile, pluginContent)

        return HookInstallReceipt(version: version, installedAt: Date())
    }

    func uninstall(fs: AIHookFileSystem) async throws {
        try await fs.removeFile(configFile)
        // Note: do NOT remove ~/.treemux/hooks/notify.sh — shared with Claude/Codex.
    }
}
