//
//  TmuxServiceTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class TmuxServiceTests: XCTestCase {

    func testParseEmptyOutput() async {
        let service = TmuxService()
        let sessions = await service.parseSessions("")
        XCTAssertTrue(sessions.isEmpty)
    }

    func testParseSingleSession() async {
        let service = TmuxService()
        let output = "dev\t3\t1\t1711382400"
        let sessions = await service.parseSessions(output)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "dev")
        XCTAssertEqual(sessions[0].windowCount, 3)
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertNotNil(sessions[0].createdAt)
    }

    func testParseMultipleSessions() async {
        let service = TmuxService()
        let output = """
        dev\t3\t1\t1711382400
        build\t1\t0\t1711382500
        """
        let sessions = await service.parseSessions(output)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].name, "dev")
        XCTAssertTrue(sessions[0].isAttached)
        XCTAssertEqual(sessions[1].name, "build")
        XCTAssertFalse(sessions[1].isAttached)
    }

    func testParseSessionWithoutTimestamp() async {
        let service = TmuxService()
        let output = "work\t2\t0"
        let sessions = await service.parseSessions(output)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].name, "work")
        XCTAssertNil(sessions[0].createdAt)
    }

    func testAttachCommand() async {
        let service = TmuxService()
        let session = TmuxSessionInfo(
            name: "dev",
            windowCount: 2,
            isAttached: false,
            createdAt: nil
        )
        let cmd = await service.attachCommand(for: session)
        XCTAssertEqual(cmd, "tmux attach-session -t dev")
    }

    func testRemoteAttachCommand() async {
        let service = TmuxService()
        let session = TmuxSessionInfo(
            name: "dev",
            windowCount: 1,
            isAttached: false,
            createdAt: nil
        )
        let target = SSHTarget(
            host: "10.0.0.1",
            port: 22,
            user: "user1",
            identityFile: nil,
            displayName: "server1",
            remotePath: nil
        )
        let cmd = await service.remoteAttachCommand(for: session, via: target)
        XCTAssertTrue(cmd.contains("ssh"))
        XCTAssertTrue(cmd.contains("-l user1"))
        XCTAssertTrue(cmd.contains("10.0.0.1"))
        XCTAssertTrue(cmd.contains("tmux attach-session -t dev"))
    }

    func testRemoteAttachCommandNonDefaultPort() async {
        let service = TmuxService()
        let session = TmuxSessionInfo(
            name: "work",
            windowCount: 1,
            isAttached: false,
            createdAt: nil
        )
        let target = SSHTarget(
            host: "server.example.com",
            port: 2222,
            user: nil,
            identityFile: nil,
            displayName: "myserver",
            remotePath: nil
        )
        let cmd = await service.remoteAttachCommand(for: session, via: target)
        XCTAssertTrue(cmd.contains("-p 2222"))
        XCTAssertFalse(cmd.contains("-l "))
    }
}
