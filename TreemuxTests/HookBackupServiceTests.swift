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
