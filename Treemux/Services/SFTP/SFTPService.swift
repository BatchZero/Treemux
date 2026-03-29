//
//  SFTPService.swift
//  Treemux
//

import Foundation
import Citadel
import Crypto
import Logging

// MARK: - Error types

enum SFTPServiceError: LocalizedError {
    case notConnected
    case noAuthMethodAvailable
    case keyFileNotFound(String)
    case unsupportedKeyType(String)
    case connectionFailed(String)

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
        case .connectionFailed(let reason):
            return "SSH connection failed: \(reason)"
        }
    }
}

// MARK: - SFTP service actor

/// Manages SFTP connections and directory operations using Citadel.
actor SFTPService {
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    /// The POSIX file-type mask for directories (S_IFDIR).
    private static let S_IFMT: UInt32 = 0o170000
    private static let S_IFDIR: UInt32 = 0o040000

    // MARK: - Connection

    /// Connect to a remote server using the given SSHTarget credentials.
    func connect(target: SSHTarget) async throws {
        // Disconnect any existing connection first
        await disconnect()

        let username = target.user ?? NSUserName()
        let authMethod = try resolveAuthMethod(username: username, identityFile: target.identityFile)

        let client = try await SSHClient.connect(
            host: target.host,
            port: target.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never,
            algorithms: .all
        )

        self.sshClient = client

        let sftp = try await client.openSFTP()
        self.sftpClient = sftp
    }

    // MARK: - Directory operations

    /// List subdirectories at the given remote path.
    ///
    /// Returns only directories (no files), excludes hidden entries (names starting with `.`),
    /// and sorts by name using localized standard comparison.
    func listDirectories(at path: String) async throws -> [SFTPDirectoryEntry] {
        guard let sftp = sftpClient else {
            throw SFTPServiceError.notConnected
        }

        let names = try await sftp.listDirectory(atPath: path)

        var entries = [SFTPDirectoryEntry]()

        for name in names {
            for component in name.components {
                let filename = component.filename

                // Skip hidden entries and special entries
                if filename.hasPrefix(".") { continue }

                // Determine if this entry is a directory.
                // Primary check: POSIX permission bits (S_IFDIR).
                // Fallback: longname starts with 'd' (ls -l style output).
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

    /// Get the home directory path on the remote server.
    ///
    /// Uses SFTP realpath on "." which resolves to the user's home directory.
    func homeDirectory() async throws -> String {
        guard let sftp = sftpClient else {
            throw SFTPServiceError.notConnected
        }

        return try await sftp.getRealPath(atPath: ".")
    }

    // MARK: - Disconnection

    /// Cleanly disconnect from the remote server.
    func disconnect() async {
        if let sftp = sftpClient {
            try? await sftp.close()
            sftpClient = nil
        }

        if let ssh = sshClient {
            try? await ssh.close()
            sshClient = nil
        }
    }

    // MARK: - Authentication helpers

    /// Resolve the SSH authentication method from the target configuration.
    ///
    /// Strategy:
    /// 1. If identityFile is specified, use that key file.
    /// 2. Otherwise, try default key paths: ~/.ssh/id_ed25519, ~/.ssh/id_rsa.
    /// 3. If no keys found, throw noAuthMethodAvailable.
    private func resolveAuthMethod(username: String, identityFile: String?) throws -> SSHAuthenticationMethod {
        if let identityFile = identityFile {
            let expandedPath = (identityFile as NSString).expandingTildeInPath
            return try authMethodFromKeyFile(at: expandedPath, username: username)
        }

        // Try default key paths
        let homeDir = NSHomeDirectory()
        let defaultKeyPaths = [
            "\(homeDir)/.ssh/id_ed25519",
            "\(homeDir)/.ssh/id_rsa"
        ]

        for keyPath in defaultKeyPaths {
            if FileManager.default.fileExists(atPath: keyPath) {
                return try authMethodFromKeyFile(at: keyPath, username: username)
            }
        }

        throw SFTPServiceError.noAuthMethodAvailable
    }

    /// Create an SSHAuthenticationMethod from a private key file.
    private func authMethodFromKeyFile(at path: String, username: String) throws -> SSHAuthenticationMethod {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SFTPServiceError.keyFileNotFound(path)
        }

        let keyContent = try String(contentsOfFile: path, encoding: .utf8)
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyContent)

        switch keyType {
        case .ed25519:
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyContent)
            return .ed25519(username: username, privateKey: privateKey)
        case .rsa:
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyContent)
            return .rsa(username: username, privateKey: privateKey)
        default:
            throw SFTPServiceError.unsupportedKeyType(keyType.description)
        }
    }
}
