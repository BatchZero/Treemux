//
//  CodexHookProvider.swift
//  Treemux
//

import Foundation

/// AIHookProvider implementation for OpenAI Codex (~/.codex/config.toml).
///
/// Codex's config is TOML, but Swift has no first-party TOML parser and we want
/// to avoid pulling in a third-party dependency. Instead we bracket our managed
/// content with comment markers and string-edit. The marker block is treated as
/// fully owned by treemux: install replaces it, uninstall removes it, and any
/// user-defined `notify` outside the block triggers a `userConfigConflict`.
struct CodexHookProvider: AIHookProvider {
    var kind: AIToolKind { .openaiCodex }
    var displayName: String { "Codex" }
    var detectionPaths: [String] { ["~/.codex/config.toml", "~/.codex"] }
    var configFile: String { "~/.codex/config.toml" }
    /// Codex needs the shared `notify.sh` (also used by Claude provider) plus
    /// its own `notify-codex.sh` adapter that translates Codex notification
    /// payloads into the form `notify.sh` expects.
    var helperResources: [String] { ["notify.sh", "notify-codex.sh"] }
    var version: String { "1" }

    private let beginMarker = "# >>> treemux-managed v1 >>>"
    private let endMarker   = "# <<< treemux-managed <<<"

    private let helperDir         = "~/.treemux/hooks"
    private let helperShared      = "~/.treemux/hooks/notify.sh"
    private let helperCodex       = "~/.treemux/hooks/notify-codex.sh"

    // MARK: - Inspect

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus {
        var detected = false
        for p in detectionPaths {
            if try await fs.exists(p) { detected = true; break }
        }
        guard detected else { return .notDetected }

        let raw = try await fs.readText(configFile) ?? ""
        guard raw.contains(beginMarker) else { return .detectedNotInstalled }

        let sharedExists = try await fs.exists(helperShared)
        let codexExists  = try await fs.exists(helperCodex)
        if sharedExists && codexExists {
            return .installed(version: version, installedAt: Date())
        } else {
            return .tampered(reason: "Codex helper script missing")
        }
    }

    // MARK: - Install

    /// Compute the planned file changes (config.toml + both helpers) without
    /// writing. Performs the user-conflict check first so callers see the
    /// `userConfigConflict` error before any filesystem effect.
    private func computeChanges(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> [HookInstallChange] {
        // Fail-fast on a user-defined `notify` outside our managed block.
        let raw = (try await fs.readText(configFile)) ?? ""
        try checkUserNotifyConflict(raw)

        var changes: [HookInstallChange] = []

        // 1) Compute proposed config.toml contents.
        let stripped = stripManagedBlock(raw)
        let block = """
        \(beginMarker)
        notify = ["$HOME/.treemux/hooks/notify-codex.sh"]
        \(endMarker)
        """
        let proposedConfig: String
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proposedConfig = block + "\n"
        } else {
            proposedConfig = stripped.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + block + "\n"
        }
        let currentConfig = try await fs.readText(configFile)
        changes.append(HookInstallChange(
            path: configFile,
            proposed: proposedConfig,
            current: currentConfig
        ))

        // 2) Compute proposed helper script contents (one entry per helper).
        for name in helperResources {
            let src = helperBundleURL.appendingPathComponent(name)
            let content: String
            do {
                content = try String(contentsOf: src, encoding: .utf8)
            } catch {
                throw HookInstallError.ioError(
                    "Cannot read bundled \(name) at \(src.path): \(error.localizedDescription)"
                )
            }
            let dest = "~/.treemux/hooks/\(name)"
            let current = try await fs.readText(dest)
            changes.append(HookInstallChange(
                path: dest,
                proposed: content,
                current: current
            ))
        }

        return changes
    }

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        let changes = try await computeChanges(fs: fs, helperBundleURL: helperBundleURL)

        // Apply: helpers first (need directory + chmod), then config.
        try await fs.makeDirectory(helperDir)
        // changes[0] is the config.toml; changes[1...] are helpers under ~/.treemux/hooks/.
        for change in changes.dropFirst() {
            try await fs.writeText(change.path, change.proposed)
            try await fs.makeExecutable(change.path)
        }
        try await fs.writeText(configFile, changes[0].proposed)

        return HookInstallReceipt(version: version, installedAt: Date())
    }

    func dryRunInstall(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> [HookInstallChange] {
        try await computeChanges(fs: fs, helperBundleURL: helperBundleURL)
    }

    // MARK: - Uninstall

    func uninstall(fs: AIHookFileSystem) async throws {
        if let raw = try await fs.readText(configFile) {
            let stripped = stripManagedBlock(raw)
            try await fs.writeText(configFile, stripped)
        }
        // Remove only the Codex-specific helper. `notify.sh` is shared with
        // the Claude provider, so we leave it in place; if Claude is also
        // uninstalled it will clean up notify.sh itself.
        try await fs.removeFile(helperCodex)
    }

    // MARK: - Helpers

    /// Throws `HookInstallError.userConfigConflict` if the user already defines
    /// a top-level `notify = ...` outside our managed block.
    private func checkUserNotifyConflict(_ raw: String) throws {
        let lines = raw.components(separatedBy: "\n")
        var insideManagedBlock = false
        for line in lines {
            if line == beginMarker { insideManagedBlock = true; continue }
            if line == endMarker { insideManagedBlock = false; continue }
            if insideManagedBlock { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("notify") && trimmed.contains("=") {
                throw HookInstallError.userConfigConflict(
                    "~/.codex/config.toml already defines `notify`. Remove or move it before installing the treemux hook."
                )
            }
        }
    }

    /// Strip the treemux-managed block (markers and content between them) from
    /// `raw`. Handles all four shapes: only-block, block-at-end, block-at-start,
    /// no-block at all. Output is normalized to "user content + trailing newline"
    /// or "" if nothing user-owned remains.
    private func stripManagedBlock(_ raw: String) -> String {
        guard let beginRange = raw.range(of: beginMarker),
              let endRange = raw.range(of: endMarker, range: beginRange.upperBound..<raw.endIndex)
        else { return raw }
        let before = String(raw[..<beginRange.lowerBound])
        var after = String(raw[endRange.upperBound...])
        if after.hasPrefix("\n") { after = String(after.dropFirst()) }
        let cleanedBefore = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAfter = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedBefore.isEmpty && cleanedAfter.isEmpty { return "" }
        if cleanedBefore.isEmpty { return cleanedAfter + "\n" }
        if cleanedAfter.isEmpty { return cleanedBefore + "\n" }
        return cleanedBefore + "\n\n" + cleanedAfter + "\n"
    }
}
