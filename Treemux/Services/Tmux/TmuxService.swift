//
//  TmuxService.swift
//  Treemux
//

import Foundation

/// Information about a tmux session.
struct TmuxSessionInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let windowCount: Int
    let isAttached: Bool
    let createdAt: Date?
}

/// Actor that detects and manages tmux sessions, both local and remote.
actor TmuxService {

    // MARK: - Local Sessions

    /// Lists all local tmux sessions.
    func listLocalSessions() async throws -> [TmuxSessionInfo] {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/env", arguments: ["tmux", "list-sessions", "-F",
            "#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}"]
        )
        return parseSessions(result.output)
    }

    /// Checks if a local tmux session is alive.
    func isSessionAlive(name: String) async -> Bool {
        do {
            let result = try await ShellCommandRunner.run(
                "/usr/bin/env", arguments: ["tmux", "has-session", "-t", name]
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    /// Returns the shell command to attach to a local tmux session.
    func attachCommand(for session: TmuxSessionInfo) -> String {
        "tmux attach-session -t \(session.name)"
    }

    // MARK: - Remote Sessions

    /// Lists tmux sessions on a remote SSH target.
    func listRemoteSessions(_ target: SSHTarget) async throws -> [TmuxSessionInfo] {
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let user = target.user {
            sshArgs.append(contentsOf: ["-l", user])
        }
        sshArgs.append(contentsOf: ["-p", String(target.port)])
        sshArgs.append(target.host)
        sshArgs.append("tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}'")

        let result = try await ShellCommandRunner.run("/usr/bin/ssh", arguments: sshArgs)
        return parseSessions(result.output)
    }

    /// Returns the shell command to attach to a remote tmux session via SSH.
    func remoteAttachCommand(for session: TmuxSessionInfo, via target: SSHTarget) -> String {
        var cmd = "ssh"
        if let user = target.user {
            cmd += " -l \(user)"
        }
        if target.port != 22 {
            cmd += " -p \(target.port)"
        }
        cmd += " \(target.host) -t 'tmux attach-session -t \(session.name)'"
        return cmd
    }

    // MARK: - Parsing

    /// Parses the output of `tmux list-sessions -F` into session info.
    func parseSessions(_ output: String) -> [TmuxSessionInfo] {
        let lines = output.components(separatedBy: .newlines)
        var sessions: [TmuxSessionInfo] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }

            let name = parts[0]
            let windowCount = Int(parts[1]) ?? 0
            let isAttached = parts[2] == "1"
            var createdAt: Date? = nil
            if parts.count >= 4, let timestamp = TimeInterval(parts[3]) {
                createdAt = Date(timeIntervalSince1970: timestamp)
            }

            sessions.append(TmuxSessionInfo(
                name: name,
                windowCount: windowCount,
                isAttached: isAttached,
                createdAt: createdAt
            ))
        }

        return sessions
    }
}
