//
//  WorkspaceModelsTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class WorkspaceModelsTests: XCTestCase {

    func testWorkspaceRecordCodableRoundTrip() throws {
        let record = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "my-project",
            repositoryPath: "/Users/test/code/my-project",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: []
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.name, "my-project")
        XCTAssertEqual(decoded.kind, .repository)
    }

    func testRemoteWorkspaceRecordCodable() throws {
        let target = SSHTarget(
            host: "server1", port: 22, user: "user1",
            identityFile: nil, displayName: "server1", remotePath: "/home/user1/proj"
        )
        let record = WorkspaceRecord(
            id: UUID(),
            kind: .remote,
            name: "proj",
            repositoryPath: nil,
            isPinned: false,
            isArchived: false,
            sshTarget: target,
            worktreeStates: []
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.kind, .remote)
        XCTAssertEqual(decoded.sshTarget?.host, "server1")
    }

    func testPersistedWorkspaceStateCodable() throws {
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: []
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.workspaces.isEmpty)
    }

    func testPaneSnapshotCodable() throws {
        let snapshot = PaneSnapshot(
            id: UUID(),
            backend: .localShell(LocalShellConfig.defaultShell()),
            workingDirectory: "/Users/test/code"
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/code")
    }
}
