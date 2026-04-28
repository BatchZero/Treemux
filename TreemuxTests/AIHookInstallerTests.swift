import XCTest
@testable import Treemux

@MainActor
final class AIHookInstallerTests: XCTestCase {

    // MARK: - Test bundle helper

    /// Temp directories created by `makeStubBundleURL` that should be cleaned
    /// up in `tearDown` so /tmp does not accumulate fake helper bundles.
    private var tempBundleDirs: [URL] = []

    override func tearDown() async throws {
        for url in tempBundleDirs {
            try? FileManager.default.removeItem(at: url)
        }
        tempBundleDirs.removeAll()
        try await super.tearDown()
    }

    /// Create a temporary directory that masquerades as the app's resource
    /// bundle for hook helper scripts. Writes a stub for each helper script
    /// name so providers can read them during `install`.
    /// - Parameters:
    ///   - helpers: list of helper script filenames to stub. Defaults to just
    ///     `notify.sh` for legacy single-helper providers (Claude).
    ///   - helperContent: content written for each stubbed script. If `nil`,
    ///     a per-name placeholder string is used.
    private func makeStubBundleURL(
        helpers: [String] = ["notify.sh"],
        helperContent: String? = nil
    ) throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-test-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for name in helpers {
            let url = tempDir.appendingPathComponent(name)
            let content = helperContent ?? "stub-\(name)"
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        tempBundleDirs.append(tempDir)
        return tempDir
    }

    // MARK: - T10 baseline tests

    func testRegistryStartsEmpty() {
        // Providers are registered in T11/T12/T13. This test guards against the
        // registry initializer doing something unexpected before then.
        let providers = AIHookProviderRegistry.providers()
        XCTAssertEqual(providers.count, 0)
    }

    func testHookTargetIDForLocal() {
        XCTAssertEqual(HookTarget.local.id, "local")
    }

    func testHookTargetIDForRemote() {
        let target = SSHTarget(
            host: "deploy.example.com",
            port: 22,
            user: nil,
            identityFile: nil,
            displayName: "deploy.example.com",
            remotePath: "/srv/app"
        )
        XCTAssertEqual(HookTarget.remote(target).id, "remote:deploy.example.com")
    }

    func testInMemoryFileSystemRoundTrip() async throws {
        let fs = InMemoryHookFileSystem()
        let exists0 = try await fs.exists("~/.foo")
        XCTAssertFalse(exists0)
        try await fs.writeText("~/.foo", "hello")
        let exists1 = try await fs.exists("~/.foo")
        XCTAssertTrue(exists1)
        let read1 = try await fs.readText("~/.foo")
        XCTAssertEqual(read1, "hello")
        try await fs.removeFile("~/.foo")
        let exists2 = try await fs.exists("~/.foo")
        XCTAssertFalse(exists2)
    }

    func testInMemoryFileSystemExecutableTracking() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.script.sh", "echo hi")
        let pre = try await fs.isExecutable("~/.script.sh")
        XCTAssertFalse(pre)
        try await fs.makeExecutable("~/.script.sh")
        let post = try await fs.isExecutable("~/.script.sh")
        XCTAssertTrue(post)
    }

    // MARK: - ClaudeCodeHookProvider (T11)

    func testClaudeCodeNotDetectedWhenSettingsAbsent() async throws {
        let fs = InMemoryHookFileSystem()
        let provider = ClaudeCodeHookProvider()
        let status = try await provider.inspect(fs: fs)
        XCTAssertEqual(status, .notDetected)
    }

    func testClaudeCodeDetectedNotInstalledForEmptyJSON() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let provider = ClaudeCodeHookProvider()
        let status = try await provider.inspect(fs: fs)
        XCTAssertEqual(status, .detectedNotInstalled)
    }

    func testClaudeCodeInstallAddsManagedHooks() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.claude/settings.json", #"{"hooks":{}}"#)
        let bundleURL = try makeStubBundleURL(helperContent: "#!/bin/sh\necho hi\n")

        let provider = ClaudeCodeHookProvider()
        let receipt = try await provider.install(fs: fs, helperBundleURL: bundleURL)
        XCTAssertEqual(receipt.version, "1")

        // Helper script written and marked executable.
        let helperWritten = try await fs.exists("~/.treemux/hooks/notify.sh")
        XCTAssertTrue(helperWritten)
        let helperExec = try await fs.isExecutable("~/.treemux/hooks/notify.sh")
        XCTAssertTrue(helperExec)
        let helperContent = try await fs.readText("~/.treemux/hooks/notify.sh")
        XCTAssertEqual(helperContent, "#!/bin/sh\necho hi\n")

        // settings.json now has managed entries under both Notification and Stop.
        let raw = try await fs.readText("~/.claude/settings.json") ?? ""
        let json = try XCTUnwrap(parseTestJSON(raw) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notif = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let stop  = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(notif.filter { ($0["_treemuxManaged"] as? Bool) == true }.count, 1)
        XCTAssertEqual(stop.filter  { ($0["_treemuxManaged"] as? Bool) == true }.count, 1)

        // Sanity: the inner command points at our helper with the right arg.
        let notifInner = try XCTUnwrap(notif.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(notifInner.first?["command"] as? String, "$HOME/.treemux/hooks/notify.sh input")
        let stopInner  = try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(stopInner.first?["command"] as? String, "$HOME/.treemux/hooks/notify.sh done")
    }

    func testClaudeCodeInstallPreservesUserHooks() async throws {
        let fs = InMemoryHookFileSystem()
        // User has a pre-existing Notification entry with their own command.
        let userJSON = #"""
        {
            "hooks": {
                "Notification": [
                    { "hooks": [{ "type": "command", "command": "echo user" }] }
                ]
            }
        }
        """#
        try await fs.writeText("~/.claude/settings.json", userJSON)
        let bundleURL = try makeStubBundleURL()

        let provider = ClaudeCodeHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        let raw = try await fs.readText("~/.claude/settings.json") ?? ""
        let json = try XCTUnwrap(parseTestJSON(raw) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notif = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])

        // Two entries total: the user's, then ours.
        XCTAssertEqual(notif.count, 2)
        let userEntries = notif.filter { ($0["_treemuxManaged"] as? Bool) != true }
        let managedEntries = notif.filter { ($0["_treemuxManaged"] as? Bool) == true }
        XCTAssertEqual(userEntries.count, 1)
        XCTAssertEqual(managedEntries.count, 1)
        // User's command was preserved.
        let userInner = try XCTUnwrap(userEntries.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(userInner.first?["command"] as? String, "echo user")
    }

    func testClaudeCodeReinstallReplacesManagedEntry() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let bundleURL = try makeStubBundleURL()

        let provider = ClaudeCodeHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        let raw = try await fs.readText("~/.claude/settings.json") ?? ""
        let json = try XCTUnwrap(parseTestJSON(raw) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notif = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        let stop  = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(notif.filter { ($0["_treemuxManaged"] as? Bool) == true }.count, 1)
        XCTAssertEqual(stop.filter  { ($0["_treemuxManaged"] as? Bool) == true }.count, 1)
        // No accidental duplicates of any kind.
        XCTAssertEqual(notif.count, 1)
        XCTAssertEqual(stop.count, 1)
    }

    func testClaudeCodeUninstallRemovesManagedAndKeepsUserHooks() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let bundleURL = try makeStubBundleURL()

        let provider = ClaudeCodeHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        // Manually inject a user-defined Stop hook entry alongside the managed one.
        let installed = try await fs.readText("~/.claude/settings.json") ?? ""
        var json = try XCTUnwrap(parseTestJSON(installed) as? [String: Any])
        var hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        var stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        stop.insert(
            ["hooks": [["type": "command", "command": "echo user-stop"]]],
            at: 0
        )
        hooks["Stop"] = stop
        json["hooks"] = hooks
        let mutated = try serializeTestJSON(json)
        try await fs.writeText("~/.claude/settings.json", mutated)

        // Now uninstall.
        try await provider.uninstall(fs: fs)

        let raw = try await fs.readText("~/.claude/settings.json") ?? ""
        let after = try XCTUnwrap(parseTestJSON(raw) as? [String: Any])
        let afterHooks = try XCTUnwrap(after["hooks"] as? [String: Any])

        // Notification: was only managed, should be gone (key removed entirely).
        XCTAssertNil(afterHooks["Notification"])

        // Stop: user entry remains, managed entry removed.
        let afterStop = try XCTUnwrap(afterHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(afterStop.count, 1)
        XCTAssertNotEqual(afterStop.first?["_treemuxManaged"] as? Bool, true)
        let inner = try XCTUnwrap(afterStop.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.first?["command"] as? String, "echo user-stop")

        // Helper script removed.
        let helperGone = try await fs.exists("~/.treemux/hooks/notify.sh")
        XCTAssertFalse(helperGone)
    }

    func testClaudeCodeInspectAfterInstallReportsInstalled() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let bundleURL = try makeStubBundleURL()

        let provider = ClaudeCodeHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        let status = try await provider.inspect(fs: fs)
        switch status {
        case .installed(let version, _):
            XCTAssertEqual(version, "1")
        default:
            XCTFail("Expected .installed, got \(status)")
        }
    }

    func testClaudeCodeTamperedWhenHelperMissing() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.claude/settings.json", "{}")
        let bundleURL = try makeStubBundleURL()

        let provider = ClaudeCodeHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        // Simulate user/system clobbering the helper script.
        try await fs.removeFile("~/.treemux/hooks/notify.sh")

        let status = try await provider.inspect(fs: fs)
        switch status {
        case .tampered(let reason):
            XCTAssertFalse(reason.isEmpty)
        default:
            XCTFail("Expected .tampered, got \(status)")
        }
    }

    // MARK: - CodexHookProvider (T12)

    func testCodexNotDetectedWithoutConfig() async throws {
        let fs = InMemoryHookFileSystem()
        let provider = CodexHookProvider()
        let status = try await provider.inspect(fs: fs)
        XCTAssertEqual(status, .notDetected)
    }

    func testCodexDetectedNotInstalledForEmptyConfig() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.codex/config.toml", "")
        let provider = CodexHookProvider()
        let status = try await provider.inspect(fs: fs)
        XCTAssertEqual(status, .detectedNotInstalled)
    }

    func testCodexInstallWritesNotifyBlock() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.codex/config.toml", "model = \"gpt-5\"\n")
        let bundleURL = try makeStubBundleURL(helpers: ["notify.sh", "notify-codex.sh"])

        let provider = CodexHookProvider()
        let receipt = try await provider.install(fs: fs, helperBundleURL: bundleURL)
        XCTAssertEqual(receipt.version, "1")

        let raw = try await fs.readText("~/.codex/config.toml") ?? ""
        XCTAssertTrue(raw.contains("# >>> treemux-managed v1 >>>"),
                      "Expected begin marker in:\n\(raw)")
        XCTAssertTrue(raw.contains("notify = [\"$HOME/.treemux/hooks/notify-codex.sh\"]"),
                      "Expected notify line in:\n\(raw)")
        XCTAssertTrue(raw.contains("model = \"gpt-5\""),
                      "Expected user content preserved in:\n\(raw)")

        // Both helpers were copied and made executable.
        let sharedExists = try await fs.exists("~/.treemux/hooks/notify.sh")
        let codexExists  = try await fs.exists("~/.treemux/hooks/notify-codex.sh")
        XCTAssertTrue(sharedExists)
        XCTAssertTrue(codexExists)
        let sharedExec = try await fs.isExecutable("~/.treemux/hooks/notify.sh")
        let codexExec  = try await fs.isExecutable("~/.treemux/hooks/notify-codex.sh")
        XCTAssertTrue(sharedExec)
        XCTAssertTrue(codexExec)
    }

    func testCodexInstallFailsOnUserNotifyConflict() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.codex/config.toml", "notify = [\"my-program\"]\n")
        let bundleURL = try makeStubBundleURL(helpers: ["notify.sh", "notify-codex.sh"])

        let provider = CodexHookProvider()

        do {
            _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)
            XCTFail("Expected userConfigConflict, got success")
        } catch {
            switch error {
            case HookInstallError.userConfigConflict(let message):
                XCTAssertTrue(message.contains("notify"))
            default:
                XCTFail("Expected userConfigConflict, got \(error)")
            }
        }

        // Helpers must NOT have been copied — install should fail before any
        // filesystem side effect.
        let sharedExists = try await fs.exists("~/.treemux/hooks/notify.sh")
        let codexExists  = try await fs.exists("~/.treemux/hooks/notify-codex.sh")
        XCTAssertFalse(sharedExists)
        XCTAssertFalse(codexExists)
    }

    func testCodexUninstallRemovesOnlyManagedBlock() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.codex/config.toml", "model = \"gpt-5\"\n")
        let bundleURL = try makeStubBundleURL(helpers: ["notify.sh", "notify-codex.sh"])

        let provider = CodexHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        try await provider.uninstall(fs: fs)

        let raw = try await fs.readText("~/.codex/config.toml") ?? ""
        XCTAssertFalse(raw.contains("# >>> treemux-managed v1 >>>"),
                       "Managed block should be gone, got:\n\(raw)")
        XCTAssertFalse(raw.contains("notify-codex.sh"),
                       "Managed notify line should be gone, got:\n\(raw)")
        XCTAssertTrue(raw.contains("model = \"gpt-5\""),
                      "User content should be preserved, got:\n\(raw)")

        // Codex-specific helper removed; shared notify.sh must remain so that
        // a still-installed Claude provider keeps working.
        let codexExists  = try await fs.exists("~/.treemux/hooks/notify-codex.sh")
        let sharedExists = try await fs.exists("~/.treemux/hooks/notify.sh")
        XCTAssertFalse(codexExists)
        XCTAssertTrue(sharedExists)
    }

    func testCodexInspectAfterInstallReportsInstalled() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.codex/config.toml", "")
        let bundleURL = try makeStubBundleURL(helpers: ["notify.sh", "notify-codex.sh"])

        let provider = CodexHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        let status = try await provider.inspect(fs: fs)
        switch status {
        case .installed(let version, _):
            XCTAssertEqual(version, "1")
        default:
            XCTFail("Expected .installed, got \(status)")
        }
    }

    func testCodexTamperedWhenHelperMissing() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.codex/config.toml", "")
        let bundleURL = try makeStubBundleURL(helpers: ["notify.sh", "notify-codex.sh"])

        let provider = CodexHookProvider()
        _ = try await provider.install(fs: fs, helperBundleURL: bundleURL)

        // Simulate user/system clobbering one of the helper scripts.
        try await fs.removeFile("~/.treemux/hooks/notify-codex.sh")

        let status = try await provider.inspect(fs: fs)
        switch status {
        case .tampered(let reason):
            XCTAssertFalse(reason.isEmpty)
        default:
            XCTFail("Expected .tampered, got \(status)")
        }
    }

    // MARK: - OpencodeHookProvider (T13)

    func testOpencodeNotDetectedWithoutConfigDir() async throws {
        let fs = InMemoryHookFileSystem()
        let status = try await OpencodeHookProvider().inspect(fs: fs)
        XCTAssertEqual(status, .notDetected)
    }

    func testOpencodeDetectedNotInstalledWhenPluginMissing() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.config/opencode/config.json", "{}")
        let status = try await OpencodeHookProvider().inspect(fs: fs)
        XCTAssertEqual(status, .detectedNotInstalled)
    }

    func testOpencodeInstallWritesPluginAndHelper() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.config/opencode/config.json", "{}")
        let bundle = try makeStubBundleURL(helpers: ["notify.sh", "treemux-notify.js"])

        _ = try await OpencodeHookProvider().install(fs: fs, helperBundleURL: bundle)

        let pluginExists = try await fs.exists("~/.config/opencode/plugins/treemux-notify.js")
        XCTAssertTrue(pluginExists)
        let helperExists = try await fs.exists("~/.treemux/hooks/notify.sh")
        XCTAssertTrue(helperExists)
        let helperExec = try await fs.isExecutable("~/.treemux/hooks/notify.sh")
        XCTAssertTrue(helperExec)
    }

    func testOpencodeUninstallKeepsSharedHelper() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.config/opencode/config.json", "{}")
        let bundle = try makeStubBundleURL(helpers: ["notify.sh", "treemux-notify.js"])
        _ = try await OpencodeHookProvider().install(fs: fs, helperBundleURL: bundle)

        try await OpencodeHookProvider().uninstall(fs: fs)

        let pluginGone = try await fs.exists("~/.config/opencode/plugins/treemux-notify.js")
        XCTAssertFalse(pluginGone)
        // Shared helper should NOT have been removed:
        let helperKept = try await fs.exists("~/.treemux/hooks/notify.sh")
        XCTAssertTrue(helperKept)
    }

    func testOpencodeInspectAfterInstallReportsInstalled() async throws {
        let fs = InMemoryHookFileSystem()
        try await fs.writeText("~/.config/opencode/config.json", "{}")
        let bundle = try makeStubBundleURL(helpers: ["notify.sh", "treemux-notify.js"])
        _ = try await OpencodeHookProvider().install(fs: fs, helperBundleURL: bundle)

        let status = try await OpencodeHookProvider().inspect(fs: fs)
        switch status {
        case .installed(let v, _):
            XCTAssertEqual(v, "1")
        default:
            XCTFail("Expected .installed, got \(status)")
        }
    }

    // MARK: - Local JSON helpers (test-only)

    private func parseTestJSON(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func serializeTestJSON(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
