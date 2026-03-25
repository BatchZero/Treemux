//
//  SessionBackendLaunch.swift
//  Treemux
//

import Foundation

// MARK: - Terminal command definition

struct TerminalCommandDefinition: Hashable {
    var executablePath: String
    var arguments: [String]
    var displayName: String
}

// MARK: - Terminal launch configuration

struct TerminalLaunchConfiguration: Hashable {
    var workingDirectory: String
    var environment: [String: String]
    var command: TerminalCommandDefinition
    var backendConfiguration: SessionBackendConfiguration

    /// Returns the full command string suitable for passing to Ghostty.
    var ghosttyCommand: String {
        ([command.executablePath] + command.arguments)
            .map(\.shellQuoted)
            .joined(separator: " ")
    }
}

// MARK: - Launch configuration factory

extension SessionBackendConfiguration {
    /// Creates a launch configuration from the backend configuration.
    func makeLaunchConfiguration(
        preferredWorkingDirectory: String,
        baseEnvironment: [String: String]
    ) -> TerminalLaunchConfiguration {
        switch self {
        case .localShell(let local):
            let command = TerminalCommandDefinition(
                executablePath: local.shellPath,
                arguments: local.arguments,
                displayName: URL(fileURLWithPath: local.shellPath).lastPathComponent
            )
            let prepared = TreemuxGhosttyShellIntegration.prepare(
                command: command,
                environment: baseEnvironment
            )
            return TerminalLaunchConfiguration(
                workingDirectory: preferredWorkingDirectory,
                environment: prepared.environment,
                command: prepared.command,
                backendConfiguration: self
            )

        case .ssh(let configuration):
            return TerminalLaunchConfiguration(
                workingDirectory: NSHomeDirectory(),
                environment: baseEnvironment,
                command: TerminalCommandDefinition(
                    executablePath: "/usr/bin/ssh",
                    arguments: configuration.sshArguments(),
                    displayName: configuration.target.displayName
                ),
                backendConfiguration: self
            )

        case .agent(let configuration):
            var environment = baseEnvironment
            for (key, value) in configuration.environment {
                environment[key] = value
            }
            let command = TerminalCommandDefinition(
                executablePath: configuration.launchCommand,
                arguments: configuration.arguments,
                displayName: configuration.name
            )
            let prepared = TreemuxGhosttyShellIntegration.prepare(
                command: command,
                environment: environment
            )
            return TerminalLaunchConfiguration(
                workingDirectory: preferredWorkingDirectory,
                environment: prepared.environment,
                command: prepared.command,
                backendConfiguration: self
            )

        case .tmuxAttach(let configuration):
            // Build an ssh+tmux or local tmux attach command.
            var arguments: [String] = []
            var executablePath = "/usr/bin/tmux"

            if configuration.isRemote, let sshTarget = configuration.sshTarget {
                executablePath = "/usr/bin/ssh"
                var sshArgs: [String] = []
                if sshTarget.port != 22 {
                    sshArgs.append(contentsOf: ["-p", String(sshTarget.port)])
                }
                if let identityFile = sshTarget.identityFile, !identityFile.isEmpty {
                    sshArgs.append(contentsOf: ["-i", identityFile])
                }
                let destination: String
                if let user = sshTarget.user {
                    destination = "\(user)@\(sshTarget.host)"
                } else {
                    destination = sshTarget.host
                }
                sshArgs.append(destination)

                var tmuxCmd = "tmux attach-session -t \(configuration.sessionName.shellQuoted)"
                if let windowIndex = configuration.windowIndex {
                    tmuxCmd += " -t \(configuration.sessionName.shellQuoted):\(windowIndex)"
                }
                sshArgs.append(tmuxCmd)
                arguments = sshArgs
            } else {
                arguments = ["attach-session", "-t", configuration.sessionName]
                if let windowIndex = configuration.windowIndex {
                    arguments = ["attach-session", "-t", "\(configuration.sessionName):\(windowIndex)"]
                }
            }

            return TerminalLaunchConfiguration(
                workingDirectory: NSHomeDirectory(),
                environment: baseEnvironment,
                command: TerminalCommandDefinition(
                    executablePath: executablePath,
                    arguments: arguments,
                    displayName: "tmux: \(configuration.sessionName)"
                ),
                backendConfiguration: self
            )
        }
    }

    /// A human-readable display name for this backend.
    var displayName: String {
        switch self {
        case .localShell:
            return "Local shell"
        case .ssh(let config):
            return config.target.displayName
        case .agent(let config):
            return config.name
        case .tmuxAttach(let config):
            return "tmux: \(config.sessionName)"
        }
    }
}

// MARK: - SSH argument builder

private extension SSHSessionConfig {
    func sshArguments() -> [String] {
        var arguments: [String] = []
        if target.port != 22 {
            arguments.append(contentsOf: ["-p", String(target.port)])
        }
        if let identityFile = target.identityFile, !identityFile.isEmpty {
            arguments.append(contentsOf: ["-i", identityFile])
        }
        let destination: String
        if let user = target.user {
            destination = "\(user)@\(target.host)"
        } else {
            destination = target.host
        }
        arguments.append(destination)
        if let remoteCommand, !remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(remoteCommand)
        }
        return arguments
    }
}
