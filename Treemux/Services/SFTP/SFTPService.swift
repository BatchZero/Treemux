//
//  SFTPService.swift
//  Treemux
//

import Foundation
import Citadel
import Crypto

// MARK: - Error types

enum SFTPServiceError: LocalizedError {
    case notConnected
    case noAuthMethodAvailable
    case keyFileNotFound(String)
    case unsupportedKeyType(String)
    case authenticationFailed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to SFTP server"
        case .noAuthMethodAvailable:
            return "No SSH authentication method available (no identity file specified and no default key found)"
        case .keyFileNotFound(let path):
            return "SSH key file not found: \(path)"
        case .unsupportedKeyType(let type):
            return "Unsupported SSH key type: \(type)"
        case .authenticationFailed:
            return "SSH authentication failed"
        case .commandFailed(let detail):
            return "SSH command failed: \(detail)"
        }
    }
}

// MARK: - Connection mode

/// Tracks how the service is connected — via system SSH or Citadel password auth.
private enum ConnectionMode {
    case ssh(SSHTarget)
    case citadel(SSHClient, SFTPClient)
}

// MARK: - SFTP service actor

/// Manages SFTP connections and directory operations.
///
/// Primary path: uses the system `ssh` command for key-based auth
/// (supports rsa-sha2-512, ed25519, agent, etc.).
/// Fallback: uses Citadel library for password-based auth.
actor SFTPService {
    private var mode: ConnectionMode?

    /// The POSIX file-type mask for directories (S_IFDIR).
    private static let S_IFMT: UInt32 = 0o170000
    private static let S_IFDIR: UInt32 = 0o040000

    // MARK: - Connection (system SSH)

    /// Connect using the system SSH client (BatchMode).
    /// Throws `.authenticationFailed` if key auth fails, so callers can prompt for password.
    func connect(target: SSHTarget) async throws {
        await disconnect()

        // Test connectivity with system ssh
        let result = try await runSSH(target: target, command: "echo __OK__")
        guard result.exitCode == 0, result.output.contains("__OK__") else {
            throw SFTPServiceError.authenticationFailed
        }

        self.mode = .ssh(target)
    }

    // MARK: - Connection (Citadel password fallback)

    /// Connect using Citadel with password authentication.
    func connectWithPassword(target: SSHTarget, password: String) async throws {
        await disconnect()

        let username = target.user ?? NSUserName()
        let authMethod = SSHAuthenticationMethod.passwordBased(username: username, password: password)

        let client = try await SSHClient.connect(
            host: target.host,
            port: target.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never,
            algorithms: .all
        )

        let sftp = try await client.openSFTP()
        self.mode = .citadel(client, sftp)
    }

    // MARK: - Directory operations

    /// List subdirectories at the given remote path.
    func listDirectories(at path: String) async throws -> [SFTPDirectoryEntry] {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            return try await listDirectoriesViaSSH(target: target, path: path)
        case .citadel(_, let sftp):
            return try await listDirectoriesViaSFTP(sftp: sftp, path: path)
        }
    }

    /// Get the home directory path on the remote server.
    func homeDirectory() async throws -> String {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            let result = try await runSSH(target: target, command: "echo $HOME")
            let home = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !home.isEmpty else {
                throw SFTPServiceError.commandFailed("Could not determine home directory")
            }
            return home
        case .citadel(_, let sftp):
            return try await sftp.getRealPath(atPath: ".")
        }
    }

    // MARK: - Disconnection

    func disconnect() async {
        guard let mode else { return }

        if case .citadel(let ssh, let sftp) = mode {
            try? await sftp.close()
            try? await ssh.close()
        }

        self.mode = nil
    }

    // MARK: - SSH directory listing

    private func listDirectoriesViaSSH(target: SSHTarget, path: String) async throws -> [SFTPDirectoryEntry] {
        // Use ls -1paL: one-per-line, append / to dirs, include hidden, dereference symlinks
        let escapedPath = shellEscape(path)
        let result = try await runSSH(target: target, command: "ls -1pa \(escapedPath)")

        guard result.exitCode == 0 else {
            throw SFTPServiceError.commandFailed("ls failed at \(path)")
        }

        let lines = result.output.components(separatedBy: "\n")
        var entries: [SFTPDirectoryEntry] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix("/") else { continue } // Only directories
            let name = String(trimmed.dropLast()) // Remove trailing /
            guard !name.isEmpty, !name.hasPrefix(".") else { continue } // Skip hidden/special

            let fullPath: String
            if path.hasSuffix("/") {
                fullPath = path + name
            } else {
                fullPath = path + "/" + name
            }
            entries.append(SFTPDirectoryEntry(name: name, path: fullPath))
        }

        return entries.sorted()
    }

    // MARK: - SFTP directory listing (Citadel)

    private func listDirectoriesViaSFTP(sftp: SFTPClient, path: String) async throws -> [SFTPDirectoryEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        var entries: [SFTPDirectoryEntry] = []

        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename.hasPrefix(".") { continue }

                let isDirectory: Bool
                if let permissions = component.attributes.permissions {
                    isDirectory = (permissions & Self.S_IFMT) == Self.S_IFDIR
                } else {
                    isDirectory = component.longname.hasPrefix("d")
                }
                guard isDirectory else { continue }

                let fullPath: String
                if path.hasSuffix("/") {
                    fullPath = path + filename
                } else {
                    fullPath = path + "/" + filename
                }
                entries.append(SFTPDirectoryEntry(name: filename, path: fullPath))
            }
        }

        return entries.sorted()
    }

    // MARK: - Process helper

    private struct SSHResult {
        let exitCode: Int32
        let output: String
    }

    private func runSSH(target: SSHTarget, command: String) async throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(target.port)"
        ]

        if let identityFile = target.identityFile {
            let expandedPath = (identityFile as NSString).expandingTildeInPath
            args += ["-i", expandedPath]
        }

        let username = target.user ?? NSUserName()
        args.append("\(username)@\(target.host)")
        args.append(command)

        process.arguments = args

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: SSHResult(exitCode: process.terminationStatus, output: output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func shellEscape(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
