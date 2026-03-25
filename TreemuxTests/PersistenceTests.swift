//
//  PersistenceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class PersistenceTests: XCTestCase {

    func testAppSettingsDefaultValues() {
        let settings = AppSettings()
        XCTAssertEqual(settings.language, "system")
        XCTAssertEqual(settings.activeThemeID, "treemux-dark")
        XCTAssertTrue(settings.startup.restoreLastSession)
    }

    func testAppSettingsCodableRoundTrip() throws {
        var settings = AppSettings()
        settings.language = "zh-Hans"
        settings.activeThemeID = "treemux-light"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.language, "zh-Hans")
        XCTAssertEqual(decoded.activeThemeID, "treemux-light")
    }

    func testTreemuxStateDirectoryName() {
        #if DEBUG
        XCTAssertEqual(treemuxStateDirectoryName(), ".treemux-debug")
        #else
        XCTAssertEqual(treemuxStateDirectoryName(), ".treemux")
        #endif
    }

    func testAppSettingsSaveAndLoad() throws {
        let persistence = AppSettingsPersistence()
        var settings = AppSettings()
        settings.language = "en"
        try persistence.save(settings)
        let loaded = persistence.load()
        XCTAssertEqual(loaded.language, "en")
    }

    func testWorkspaceStateSaveAndLoad() throws {
        let persistence = WorkspaceStatePersistence()
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [
                WorkspaceRecord(
                    id: UUID(), kind: .repository, name: "test",
                    repositoryPath: "/tmp/test", isPinned: false,
                    isArchived: false, sshTarget: nil, worktreeStates: []
                )
            ]
        )
        try persistence.save(state)
        let loaded = persistence.load()
        XCTAssertEqual(loaded.workspaces.count, 1)
        XCTAssertEqual(loaded.workspaces.first?.name, "test")
    }
}
