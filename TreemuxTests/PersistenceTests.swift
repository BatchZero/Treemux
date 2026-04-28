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

    func testAppSettingsDefaultsForNewFields() {
        let settings = AppSettings()
        XCTAssertTrue(settings.aiActivityHintsEnabled)
        XCTAssertTrue(settings.aiHookSkippedKeys.isEmpty)
    }

    func testAppSettingsRoundTripPreservesNewFields() throws {
        var settings = AppSettings()
        settings.aiActivityHintsEnabled = false
        settings.aiHookSkippedKeys = ["workspace-uuid:claude", "workspace-uuid:codex"]

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.aiActivityHintsEnabled, false)
        XCTAssertEqual(decoded.aiHookSkippedKeys.count, 2)
        XCTAssertEqual(Set(decoded.aiHookSkippedKeys), Set(["workspace-uuid:claude", "workspace-uuid:codex"]))
    }

    func testAppSettingsBackwardCompatibilityForMissingNewFields() throws {
        // Older JSON written before T16 lacks the two new keys — decode should
        // succeed with defaults, NOT throw.
        let oldJSON = #"""
        {
            "version": 1,
            "language": "system",
            "activeThemeID": "treemux-dark",
            "appearance": "system"
        }
        """#
        let data = oldJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.aiActivityHintsEnabled, "Default should kick in")
        XCTAssertEqual(decoded.aiHookSkippedKeys, [], "Default should kick in")
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
}
