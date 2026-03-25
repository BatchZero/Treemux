import XCTest
@testable import Treemux

final class SessionBackendTests: XCTestCase {

    func testLocalShellCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.localShell(LocalShellConfig(
            shellPath: "/bin/zsh",
            arguments: ["--login"]
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .localShell(let shell) = decoded {
            XCTAssertEqual(shell.shellPath, "/bin/zsh")
            XCTAssertEqual(shell.arguments, ["--login"])
        } else {
            XCTFail("Expected localShell")
        }
    }

    func testSSHTargetCodableRoundTrip() throws {
        let target = SSHTarget(
            host: "192.168.1.100",
            port: 22,
            user: "user1",
            identityFile: "~/.ssh/id_rsa",
            displayName: "server1",
            remotePath: "/home/user1/project"
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(SSHTarget.self, from: data)
        XCTAssertEqual(decoded.host, "192.168.1.100")
        XCTAssertEqual(decoded.user, "user1")
        XCTAssertEqual(decoded.displayName, "server1")
    }

    func testTmuxAttachCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.tmuxAttach(TmuxAttachConfig(
            sessionName: "dev",
            windowIndex: nil,
            isRemote: true,
            sshTarget: SSHTarget(
                host: "server1",
                port: 22,
                user: "user1",
                identityFile: nil,
                displayName: "server1",
                remotePath: nil
            )
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .tmuxAttach(let tmux) = decoded {
            XCTAssertEqual(tmux.sessionName, "dev")
            XCTAssertTrue(tmux.isRemote)
            XCTAssertEqual(tmux.sshTarget?.host, "server1")
        } else {
            XCTFail("Expected tmuxAttach")
        }
    }

    func testAgentConfigCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.agent(AgentSessionConfig(
            name: "Claude Code",
            launchCommand: "claude",
            arguments: [],
            environment: [:],
            toolKind: .claudeCode
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .agent(let agent) = decoded {
            XCTAssertEqual(agent.name, "Claude Code")
            XCTAssertEqual(agent.toolKind, .claudeCode)
        } else {
            XCTFail("Expected agent")
        }
    }
}
