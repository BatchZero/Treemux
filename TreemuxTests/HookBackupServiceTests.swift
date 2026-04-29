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
}
