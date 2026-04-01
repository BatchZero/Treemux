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

    // MARK: - Launch configuration tests

    private func makeSSHTarget(
        host: String = "server1",
        port: Int = 22,
        user: String? = "user1",
        identityFile: String? = nil
    ) -> SSHTarget {
        SSHTarget(
            host: host,
            port: port,
            user: user,
            identityFile: identityFile,
            displayName: host,
            remotePath: nil
        )
    }

    func testRemoteTmuxAttachIncludesPTYFlag() {
        let config = SessionBackendConfiguration.tmuxAttach(TmuxAttachConfig(
            sessionName: "dev",
            windowIndex: nil,
            isRemote: true,
            sshTarget: makeSSHTarget()
        ))
        let launch = config.makeLaunchConfiguration(
            preferredWorkingDirectory: NSHomeDirectory(),
            baseEnvironment: [:]
        )
        XCTAssertEqual(launch.command.executablePath, "/usr/bin/ssh")
        XCTAssertTrue(
            launch.command.arguments.contains("-t"),
            "Remote tmux attach must include -t for PTY allocation"
        )
    }

    func testSSHPlainInjectsSetTitlesAndLoginShell() {
        let config = SessionBackendConfiguration.ssh(SSHSessionConfig(
            target: makeSSHTarget(),
            remoteCommand: nil
        ))
        let launch = config.makeLaunchConfiguration(
            preferredWorkingDirectory: NSHomeDirectory(),
            baseEnvironment: [:]
        )
        let args = launch.command.arguments
        XCTAssertTrue(args.contains("-t"), "Plain SSH must include -t for PTY allocation")
        let remoteCmd = args.last!
        XCTAssertTrue(
            remoteCmd.contains("tmux set-option -g set-titles on"),
            "SSH must inject tmux set-titles on"
        )
        XCTAssertTrue(
            remoteCmd.contains("exec $SHELL -l"),
            "Plain SSH must start a login shell"
        )
    }

    func testSSHWithRemoteCommandInjectsSetTitles() {
        let config = SessionBackendConfiguration.ssh(SSHSessionConfig(
            target: makeSSHTarget(),
            remoteCommand: "htop"
        ))
        let launch = config.makeLaunchConfiguration(
            preferredWorkingDirectory: NSHomeDirectory(),
            baseEnvironment: [:]
        )
        let args = launch.command.arguments
        let remoteCmd = args.last!
        XCTAssertTrue(
            remoteCmd.hasPrefix("tmux set-option -g set-titles on 2>/dev/null;"),
            "Remote command must be prefixed with set-titles injection"
        )
        XCTAssertTrue(
            remoteCmd.contains("htop"),
            "Original remote command must be preserved"
        )
    }

    func testSSHWithWorkingDirectoryInjectsSetTitles() {
        let config = SessionBackendConfiguration.ssh(SSHSessionConfig(
            target: makeSSHTarget(),
            remoteCommand: nil
        ))
        let launch = config.makeLaunchConfiguration(
            preferredWorkingDirectory: "/tmp/test-project",
            baseEnvironment: [:]
        )
        let args = launch.command.arguments
        let remoteCmd = args.last!
        XCTAssertTrue(
            remoteCmd.contains("tmux set-option -g set-titles on"),
            "SSH with working directory must inject set-titles"
        )
        XCTAssertTrue(
            remoteCmd.contains("cd '/tmp/test-project'"),
            "Must cd to the preferred working directory"
        )
    }
}
