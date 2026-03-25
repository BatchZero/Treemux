//
//  SessionBackend.swift
//  Treemux
//

import Foundation

// MARK: - Local shell configuration

struct LocalShellConfig: Codable {
    let shellPath: String
    let arguments: [String]

    /// Returns a configuration using the user's default shell.
    static func defaultShell() -> LocalShellConfig {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return LocalShellConfig(shellPath: shell, arguments: ["--login"])
    }
}

// MARK: - SSH session configuration

struct SSHSessionConfig: Codable {
    let target: SSHTarget
    let remoteCommand: String?
}

// MARK: - AI tool kind

enum AIToolKind: String, Codable {
    case claudeCode = "claude"
    case openaiCodex = "codex"
    case custom
}

// MARK: - Agent session configuration

struct AgentSessionConfig: Codable {
    let name: String
    let launchCommand: String
    let arguments: [String]
    let environment: [String: String]
    let toolKind: AIToolKind?
}

// MARK: - Tmux attach configuration

struct TmuxAttachConfig: Codable {
    let sessionName: String
    let windowIndex: Int?
    let isRemote: Bool
    let sshTarget: SSHTarget?
}

// MARK: - Session backend configuration

enum SessionBackendConfiguration: Codable {
    case localShell(LocalShellConfig)
    case ssh(SSHSessionConfig)
    case agent(AgentSessionConfig)
    case tmuxAttach(TmuxAttachConfig)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum BackendType: String, Codable {
        case localShell, ssh, agent, tmuxAttach
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localShell(let config):
            try container.encode(BackendType.localShell, forKey: .type)
            try config.encode(to: encoder)
        case .ssh(let config):
            try container.encode(BackendType.ssh, forKey: .type)
            try config.encode(to: encoder)
        case .agent(let config):
            try container.encode(BackendType.agent, forKey: .type)
            try config.encode(to: encoder)
        case .tmuxAttach(let config):
            try container.encode(BackendType.tmuxAttach, forKey: .type)
            try config.encode(to: encoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BackendType.self, forKey: .type)
        switch type {
        case .localShell:
            self = .localShell(try LocalShellConfig(from: decoder))
        case .ssh:
            self = .ssh(try SSHSessionConfig(from: decoder))
        case .agent:
            self = .agent(try AgentSessionConfig(from: decoder))
        case .tmuxAttach:
            self = .tmuxAttach(try TmuxAttachConfig(from: decoder))
        }
    }
}
