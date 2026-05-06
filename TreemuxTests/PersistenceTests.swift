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
        XCTAssertEqual(settings.defaultLocalTerminalIcon, .localTerminalDefault)
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
                    isArchived: false, sshTarget: nil, worktreeStates: [],
                    worktreeOrder: nil,
                    workspaceIcon: nil,
                    worktreeIconOverrides: nil
                )
            ]
        )
        try persistence.save(state)
        let loaded = persistence.load()
        XCTAssertEqual(loaded.workspaces.count, 1)
        XCTAssertEqual(loaded.workspaces.first?.name, "test")
    }

    func testWorkspaceTabStatePersistenceRoundTrip() throws {
        let tabID = UUID()
        let paneID = UUID()
        let tab = WorkspaceTabStateRecord(
            id: tabID,
            title: "My Tab",
            isManuallyNamed: true,
            layout: .pane(PaneLeaf(paneID: paneID)),
            panes: [PaneSnapshot(
                id: paneID,
                backend: .localShell(LocalShellConfig.defaultShell()),
                workingDirectory: "/tmp"
            )],
            focusedPaneID: paneID,
            zoomedPaneID: nil
        )
        let worktreeState = WorktreeSessionStateRecord(
            worktreePath: "/tmp/project",
            branch: "main",
            tabs: [tab],
            selectedTabID: tabID
        )
        let workspace = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "test",
            repositoryPath: "/tmp/project",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [worktreeState],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil
        )
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace]
        )

        let persistence = WorkspaceStatePersistence()
        try persistence.save(state)
        let loaded = persistence.load()

        XCTAssertEqual(loaded.workspaces.count, 1)
        let loadedWS = loaded.workspaces[0]
        XCTAssertEqual(loadedWS.worktreeStates.count, 1)
        XCTAssertEqual(loadedWS.worktreeStates[0].tabs.count, 1)
        XCTAssertEqual(loadedWS.worktreeStates[0].tabs[0].title, "My Tab")
        XCTAssertTrue(loadedWS.worktreeStates[0].tabs[0].isManuallyNamed)
        XCTAssertEqual(loadedWS.worktreeStates[0].selectedTabID, tabID)
    }


    func testWorkspaceTabStateMigrationFromEmptyTabs() throws {
        let workspace = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "legacy",
            repositoryPath: "/tmp/legacy",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: [],
            worktreeOrder: nil,
            workspaceIcon: nil,
            worktreeIconOverrides: nil
        )
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertTrue(decoded.worktreeStates.isEmpty)
    }

    func testAppSettingsShowDefaultTerminalDefaultsTrue() {
        let settings = AppSettings()
        XCTAssertTrue(settings.showDefaultTerminal)
    }

    func testAppSettingsShowDefaultTerminalLegacyJSONDefaultsTrue() throws {
        // Old settings JSON without showDefaultTerminal must decode with showDefaultTerminal == true.
        // Build "legacy" JSON by encoding default AppSettings, parsing to a dictionary,
        // removing the new key, then re-encoding. This is robust to the on-disk shape of
        // nested types like SidebarItemIcon.
        let defaults = AppSettings()
        let encoded = try JSONEncoder().encode(defaults)
        guard var dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            XCTFail("Encoded AppSettings was not a JSON object")
            return
        }
        dict.removeValue(forKey: "showDefaultTerminal")
        XCTAssertNil(dict["showDefaultTerminal"], "Legacy JSON must not contain showDefaultTerminal")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        XCTAssertTrue(decoded.showDefaultTerminal)
    }

    // MARK: - TerminalSettings migration

    func testTerminalSettings_decodesNewFontSizeOffset() throws {
        let json = #"{"defaultShell":"/bin/zsh","fontSizeOffset":3,"cursorStyle":"bar"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 3)
        XCTAssertEqual(decoded.defaultShell, "/bin/zsh")
        XCTAssertEqual(decoded.cursorStyle, "bar")
    }

    func testTerminalSettings_decodesLegacyFontSize_18_toOffset4() throws {
        let json = #"{"defaultShell":"/bin/zsh","fontSize":18,"cursorStyle":"bar"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 4)
    }

    func testTerminalSettings_decodesLegacyFontSize_8_toOffsetMinus6() throws {
        let json = #"{"fontSize":8}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, -6)
    }

    func testTerminalSettings_decodesLegacyFontSize_99_clampsToUpperBound() throws {
        let json = #"{"fontSize":99}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 12)
    }

    func testTerminalSettings_decodesLegacyFontSize_0_clampsToLowerBound() throws {
        let json = #"{"fontSize":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, -8)
    }

    func testTerminalSettings_missingBoth_defaultsToZero() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 0)
    }

    func testTerminalSettings_encode_doesNotWriteLegacyFontSize() throws {
        var settings = TerminalSettings()
        settings.fontSizeOffset = 2
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("fontSizeOffset"), "encoded JSON missing fontSizeOffset")
        XCTAssertFalse(json.contains("\"fontSize\""), "encoded JSON should not contain legacy fontSize key")
    }

    func testTerminalSettings_newOffsetTakesPrecedenceOverLegacyFontSize() throws {
        let json = #"{"fontSize":20,"fontSizeOffset":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 1)
    }

    func testTerminalSettings_legacyMigration_isIdempotentAcrossReencode() throws {
        let legacyJSON = #"{"defaultShell":"/bin/zsh","fontSize":18,"cursorStyle":"bar"}"#.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(TerminalSettings.self, from: legacyJSON)
        let reEncoded = try JSONEncoder().encode(migrated)
        let reDecoded = try JSONDecoder().decode(TerminalSettings.self, from: reEncoded)
        XCTAssertEqual(reDecoded.fontSizeOffset, 4)
        XCTAssertEqual(reDecoded, migrated)
        let reEncodedString = String(data: reEncoded, encoding: .utf8) ?? ""
        XCTAssertFalse(reEncodedString.contains("\"fontSize\""), "re-encoded JSON should not reintroduce the legacy fontSize key")
    }
}
