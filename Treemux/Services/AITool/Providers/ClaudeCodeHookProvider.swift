//
//  ClaudeCodeHookProvider.swift
//  Treemux
//

import Foundation

/// AIHookProvider implementation for Claude Code (~/.claude/settings.json).
/// Installs `Notification` and `Stop` hook entries that invoke the bundled
/// `notify.sh` helper, marked with `_treemuxManaged: true` so we can later
/// detect, replace (idempotent reinstall), or remove only our own entries
/// without disturbing user-defined hooks.
struct ClaudeCodeHookProvider: AIHookProvider {
    var kind: AIToolKind { .claudeCode }
    var displayName: String { "Claude Code" }
    var detectionPaths: [String] { ["~/.claude/settings.json", "~/.claude"] }
    var configFile: String { "~/.claude/settings.json" }
    var helperResources: [String] { ["notify.sh"] }
    var version: String { "1" }

    private let helperPath = "~/.treemux/hooks/notify.sh"
    private let helperDir  = "~/.treemux/hooks"

    // MARK: - Inspect

    func inspect(fs: AIHookFileSystem) async throws -> HookStatus {
        // Detection: any-of detectionPaths must exist.
        var detected = false
        for p in detectionPaths {
            if try await fs.exists(p) {
                detected = true
                break
            }
        }
        guard detected else { return .notDetected }

        // Read settings.json (optional).
        guard let raw = try await fs.readText(configFile) else {
            return .detectedNotInstalled
        }

        // Parse; an unparseable file is "tampered".
        guard let json = parseJSON(raw) as? [String: Any] else {
            return .tampered(reason: "settings.json is not valid JSON")
        }

        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let hasNotif = anyManaged(in: hooks["Notification"])
        let hasStop  = anyManaged(in: hooks["Stop"])

        guard hasNotif && hasStop else { return .detectedNotInstalled }

        // Managed entries present — ensure helper script is also on disk.
        if try await fs.exists(helperPath) {
            return .installed(version: version, installedAt: Date())
        }
        return .tampered(reason: "Helper script missing at \(helperPath)")
    }

    // MARK: - Install

    func install(fs: AIHookFileSystem, helperBundleURL: URL) async throws -> HookInstallReceipt {
        // 1) Copy helper script from bundle URL to ~/.treemux/hooks/notify.sh.
        let src = helperBundleURL.appendingPathComponent("notify.sh")
        let helperContent: String
        do {
            helperContent = try String(contentsOf: src, encoding: .utf8)
        } catch {
            throw HookInstallError.ioError(
                "Cannot read bundled notify.sh at \(src.path): \(error.localizedDescription)"
            )
        }
        try await fs.makeDirectory(helperDir)
        try await fs.writeText(helperPath, helperContent)
        try await fs.makeExecutable(helperPath)

        // 2) Load existing settings.json (or seed an empty object).
        let raw = (try await fs.readText(configFile)) ?? "{}"
        guard var json = parseJSON(raw) as? [String: Any] else {
            throw HookInstallError.parseError("settings.json: not valid JSON")
        }

        // 3) Merge managed entries under hooks.Notification / hooks.Stop.
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let notifEntry: [String: Any] = [
            "_treemuxManaged": true,
            "_treemuxVersion": version,
            "hooks": [
                ["type": "command", "command": "$HOME/.treemux/hooks/notify.sh input"]
            ]
        ]
        let stopEntry: [String: Any] = [
            "_treemuxManaged": true,
            "_treemuxVersion": version,
            "hooks": [
                ["type": "command", "command": "$HOME/.treemux/hooks/notify.sh done"]
            ]
        ]
        hooks["Notification"] = appendOrReplaceManaged(in: hooks["Notification"], with: notifEntry)
        hooks["Stop"]         = appendOrReplaceManaged(in: hooks["Stop"], with: stopEntry)
        json["hooks"] = hooks

        // 4) Re-serialize and write back.
        try await fs.writeText(configFile, try serializeJSON(json))
        return HookInstallReceipt(version: version, installedAt: Date())
    }

    // MARK: - Uninstall

    func uninstall(fs: AIHookFileSystem) async throws {
        if let raw = try await fs.readText(configFile),
           var json = parseJSON(raw) as? [String: Any] {
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            // Strip managed entries; if a category becomes empty, drop the key.
            if let cleaned = removeManaged(in: hooks["Notification"]) {
                hooks["Notification"] = cleaned
            } else {
                hooks.removeValue(forKey: "Notification")
            }
            if let cleaned = removeManaged(in: hooks["Stop"]) {
                hooks["Stop"] = cleaned
            } else {
                hooks.removeValue(forKey: "Stop")
            }
            json["hooks"] = hooks
            try await fs.writeText(configFile, try serializeJSON(json))
        }
        // Always try to remove the helper; removeFile is a no-op if absent.
        try await fs.removeFile(helperPath)
    }

    // MARK: - JSON helpers

    private func anyManaged(in any: Any?) -> Bool {
        guard let arr = any as? [[String: Any]] else { return false }
        return arr.contains { ($0["_treemuxManaged"] as? Bool) == true }
    }

    /// Replace any existing managed entry, then append the new managed entry.
    /// Preserves all user-defined entries in their original order.
    private func appendOrReplaceManaged(in existing: Any?, with entry: [String: Any]) -> [[String: Any]] {
        var arr = (existing as? [[String: Any]]) ?? []
        arr.removeAll { ($0["_treemuxManaged"] as? Bool) == true }
        arr.append(entry)
        return arr
    }

    /// Drop managed entries; return nil if the array becomes empty so the
    /// caller can clean up the parent key entirely.
    private func removeManaged(in existing: Any?) -> [[String: Any]]? {
        guard var arr = existing as? [[String: Any]] else { return nil }
        arr.removeAll { ($0["_treemuxManaged"] as? Bool) == true }
        return arr.isEmpty ? nil : arr
    }

    private func parseJSON(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func serializeJSON(_ obj: Any) throws -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw HookInstallError.parseError("serialize: \(error.localizedDescription)")
        }
    }
}
