//
//  HookBackupServiceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

@MainActor
final class HookBackupServiceTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempHome)
        try await super.tearDown()
    }

    private func fixedNow(_ y: Int = 2026, _ mo: Int = 4, _ d: Int = 29,
                          _ h: Int = 15, _ mi: Int = 30, _ s: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        c.hour = h; c.minute = mi; c.second = s
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testBackupLocalWritesExpectedPath() async throws {
        let service = HookBackupService(
            now: { self.fixedNow() },
            home: tempHome
        )
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{\n  \"hooks\": { \"x\": 1 }\n}\n",
            current: "{\n  \"hooks\": {}\n}\n"
        )

        let result = try await service.backup(
            change: change,
            target: .local,
            provider: ClaudeCodeHookProvider()
        )

        let expected = tempHome
            .appendingPathComponent(".treemux/backups/local/claude/settings.json.20260429-153012")
        XCTAssertEqual(result.localPath.path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        let written = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertEqual(written, change.current)
    }

    func testBackupRemoteSanitizesColonInTargetID() async throws {
        let service = HookBackupService(
            now: { self.fixedNow() },
            home: tempHome
        )
        let ssh = SSHTarget(
            host: "user@example.com",
            port: 22,
            user: "user",
            identityFile: nil,
            displayName: "user@example.com",
            remotePath: nil
        )
        let change = HookInstallChange(
            path: "~/.codex/config.toml",
            proposed: "x = 2",
            current: "x = 1"
        )

        let result = try await service.backup(
            change: change,
            target: .remote(ssh),
            provider: CodexHookProvider()
        )

        let expected = tempHome
            .appendingPathComponent(".treemux/backups/remote_user@example.com/codex/config.toml.20260429-153012")
        XCTAssertEqual(result.localPath.path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testBackupThrowsWhenCurrentIsNil() async throws {
        let service = HookBackupService(
            now: { self.fixedNow() },
            home: tempHome
        )
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: nil
        )

        do {
            _ = try await service.backup(
                change: change,
                target: .local,
                provider: ClaudeCodeHookProvider()
            )
            XCTFail("Expected HookInstallError.ioError when change.current is nil")
        } catch HookInstallError.ioError(let msg) {
            XCTAssertTrue(msg.contains("Nothing to back up"),
                          "Unexpected error message: \(msg)")
        } catch {
            XCTFail("Expected HookInstallError.ioError, got: \(error)")
        }
    }

    func testBackupTwiceProducesDistinctFiles() async throws {
        var counter = 0
        let service = HookBackupService(
            now: {
                counter += 1
                return self.fixedNow(2026, 4, 29, 15, 30, counter)
            },
            home: tempHome
        )
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{}"
        )

        let first = try await service.backup(
            change: change,
            target: .local,
            provider: ClaudeCodeHookProvider()
        )
        let second = try await service.backup(
            change: change,
            target: .local,
            provider: ClaudeCodeHookProvider()
        )

        XCTAssertNotEqual(first.localPath, second.localPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.localPath.path))
    }

    func testBackupSameSecondAppendsSuffix() async throws {
        // Same fixed timestamp on every call: forces filename collision.
        let service = HookBackupService(now: { self.fixedNow() }, home: tempHome)
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{}"
        )

        let first = try await service.backup(change: change, target: .local,
                                             provider: ClaudeCodeHookProvider())
        let second = try await service.backup(change: change, target: .local,
                                              provider: ClaudeCodeHookProvider())
        let third = try await service.backup(change: change, target: .local,
                                             provider: ClaudeCodeHookProvider())

        XCTAssertNotEqual(first.localPath, second.localPath)
        XCTAssertNotEqual(second.localPath, third.localPath)
        XCTAssertEqual(first.localPath.lastPathComponent,
                       "settings.json.20260429-153012")
        XCTAssertEqual(second.localPath.lastPathComponent,
                       "settings.json.20260429-153012-2")
        XCTAssertEqual(third.localPath.lastPathComponent,
                       "settings.json.20260429-153012-3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.localPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.localPath.path))
    }

    func testBackupSanitizesPathTraversalCharsInHost() async throws {
        let service = HookBackupService(now: { self.fixedNow() }, home: tempHome)
        // Host with path-segment-hostile characters.
        let target = HookTarget.remote(SSHTarget(
            host: "../../etc/passwd/host",
            port: 22,
            user: "u",
            identityFile: nil,
            displayName: "evil",
            remotePath: nil
        ))
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{}"
        )

        let result = try await service.backup(
            change: change, target: target,
            provider: ClaudeCodeHookProvider()
        )

        // Backup must stay strictly under tempHome/.treemux/backups/.
        let safeRoot = tempHome.appendingPathComponent(".treemux/backups", isDirectory: true)
        XCTAssertTrue(result.localPath.path.hasPrefix(safeRoot.path),
                      "backup path \(result.localPath.path) escaped the safe root")
        // The slashes and dots in the host were replaced with underscores.
        XCTAssertFalse(result.localPath.path.contains("/etc/"))
        XCTAssertFalse(result.localPath.path.contains("/.."))
    }

    func testBackupCreatesMissingIntermediateDirectories() async throws {
        let dotTreemux = tempHome.appendingPathComponent(".treemux")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dotTreemux.path),
                       "tempHome/.treemux must not exist before backup")

        let service = HookBackupService(
            now: { self.fixedNow() },
            home: tempHome
        )
        let change = HookInstallChange(
            path: "~/.claude/settings.json",
            proposed: "{}",
            current: "{}"
        )

        _ = try await service.backup(
            change: change,
            target: .local,
            provider: ClaudeCodeHookProvider()
        )

        let expectedDir = tempHome
            .appendingPathComponent(".treemux/backups/local/claude")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDir.path,
                                                     isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
