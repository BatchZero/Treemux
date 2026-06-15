//
//  SSHConfigServiceWriteTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class SSHConfigServiceWriteTests: XCTestCase {

    private func makeTempConfigPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config").path
    }

    func testAddCreatesFileWith0600() async throws {
        let path = try makeTempConfigPath()
        let service = SSHConfigService(configPaths: [path])
        try await service.add(SSHServerDraft(alias: "s", hostName: "h"))

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("Host s"))
        XCTAssertTrue(content.hasSuffix("\n"))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testLoadManagedEntriesTagsSourcePath() async throws {
        let path = try makeTempConfigPath()
        try "Host one\n    HostName 1.1.1.1\nHost *\n    ForwardAgent yes"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let service = SSHConfigService(configPaths: [path])

        let entries = await service.loadManagedEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].draft.alias, "one")
        XCTAssertEqual(entries[0].sourcePath, path)
        XCTAssertTrue(entries[0].isEditable)
        XCTAssertFalse(entries[1].isEditable)
    }

    func testUpdateAndRemoveRoundTrip() async throws {
        let path = try makeTempConfigPath()
        try "Host s\n    HostName old\n    # note"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let service = SSHConfigService(configPaths: [path])

        try await service.update(SSHServerDraft(alias: "s", hostName: "new"),
                                 originalAlias: "s", atSourcePath: path)
        var content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("HostName new"))
        XCTAssertTrue(content.contains("# note"))   // unknown content preserved

        try await service.remove(alias: "s", atSourcePath: path)
        content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(content.contains("Host s"))
    }
}
