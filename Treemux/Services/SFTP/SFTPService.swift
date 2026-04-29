//
//  SFTPService.swift
//  Treemux
//

import Foundation
import Citadel
import Crypto
import NIOCore

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

    /// Whether this service currently holds an active SSH/SFTP connection.
    /// Used by data sources sharing one service to avoid redundant `connect()` calls,
    /// which would tear down sibling sessions via the leading `disconnect()`.
    var isConnected: Bool { mode != nil }

    /// The POSIX file-type mask for directories (S_IFDIR).
    private static let S_IFMT: UInt32 = 0o170000
    private static let S_IFDIR: UInt32 = 0o040000
    private static let S_IFLNK: UInt32 = 0o120000
    private static let S_IFREG: UInt32 = 0o100000

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

    // MARK: - Rich listing / stat / read / write

    /// List ALL entries (files + directories + symlinks) at the given remote path.
    /// Includes size and mtime metadata where available.
    func listAllEntries(at path: String) async throws -> [SFTPRichEntry] {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            return try await listAllEntriesViaSSH(target: target, path: path)
        case .citadel(_, let sftp):
            return try await listAllEntriesViaSFTP(sftp: sftp, path: path)
        }
    }

    /// Stat a single remote path.
    func stat(_ path: String) async throws -> SFTPRichStat {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            return try await statViaSSH(target: target, path: path)
        case .citadel(_, let sftp):
            return try await statViaSFTP(sftp: sftp, path: path)
        }
    }

    /// Read the contents of a remote file. Refuses files larger than `maxBytes`.
    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            return try await readFileViaSSH(target: target, path: path, maxBytes: maxBytes)
        case .citadel(_, let sftp):
            return try await readFileViaSFTP(sftp: sftp, path: path, maxBytes: maxBytes)
        }
    }

    /// Write `data` to the given remote file path, creating or truncating as needed.
    func writeFile(at path: String, data: Data) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            try await writeFileViaSSH(target: target, path: path, data: data)
        case .citadel(_, let sftp):
            try await writeFileViaSFTP(sftp: sftp, path: path, data: data)
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

    // MARK: - SSH stdin helper

    /// Like `runSSH(target:command:)` but feeds `stdin` to the remote command's standard input.
    private func runSSHWithStdin(target: SSHTarget, command: String, stdin: String) async throws -> SSHResult {
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

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: SSHResult(exitCode: process.terminationStatus, output: output))
            }
            do {
                try process.run()
                if let stdinData = stdin.data(using: .utf8) {
                    try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                }
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - SSH rich listing

    /// List all entries via the system `ssh` client. Uses Linux-style `ls -lA --time-style=+%s`.
    /// macOS/BSD `ls` doesn't support `--time-style=+%s` — falls back to `ls -lAT` and parses the
    /// `Mon DD HH:MM:SS YYYY` timestamp format.
    /// TODO: cross-vendor parse — formal feature detection rather than fall-through retry.
    private func listAllEntriesViaSSH(target: SSHTarget, path: String) async throws -> [SFTPRichEntry] {
        let escapedPath = shellEscape(path)

        // Try GNU coreutils first (Linux). If that fails (likely macOS/BSD), retry with -T.
        let gnuCmd = "ls -lA --time-style=+%s -- \(escapedPath)"
        let bsdCmd = "ls -lAT -- \(escapedPath)"
        let combined = "\(gnuCmd) 2>/dev/null || \(bsdCmd)"

        let result = try await runSSH(target: target, command: combined)
        guard result.exitCode == 0 else {
            throw SFTPServiceError.commandFailed("ls failed at \(path)")
        }

        return parseListing(output: result.output, parentPath: path)
    }

    /// Parse `ls -lA` style output. Auto-detects whether the timestamp is a single epoch field
    /// (Linux `--time-style=+%s`) or 4 BSD fields (`Mon DD HH:MM:SS YYYY`).
    private func parseListing(output: String, parentPath: String) -> [SFTPRichEntry] {
        var entries: [SFTPRichEntry] = []

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("total ") { continue }

            // Tokenize by whitespace; collapse runs.
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Minimum: perms links owner group size <date...> name
            // GNU --time-style=+%s: 7 tokens before name → 8+
            // BSD `ls -lAT`:        10 tokens before name → 11+
            guard tokens.count >= 8 else { continue }

            let perms = tokens[0]
            guard !perms.isEmpty else { continue }

            // Determine kind from the leading char of `perms`.
            let typeChar = perms.first!
            let kind: SFTPRichEntry.Kind
            switch typeChar {
            case "d": kind = .directory
            case "l": kind = .symlink(target: nil) // Will fill in below if available.
            case "-": kind = .file
            default:
                // Block/char devices/sockets/fifos — treat as file for browser purposes.
                kind = .file
            }

            // Find the size column. Owner+group may be 1 or 2 tokens depending on `ls` flags.
            // Standard layout: tokens[0]=perms, [1]=links, [2]=owner, [3]=group, [4]=size.
            guard tokens.count >= 5, let size = Int64(tokens[4]) else { continue }

            // Detect timestamp format: GNU is a single epoch integer at index 5.
            let mtime: Date?
            let nameStartIdx: Int
            if tokens.count > 6, let epoch = Int64(tokens[5]) {
                mtime = Date(timeIntervalSince1970: TimeInterval(epoch))
                nameStartIdx = 6
            } else if tokens.count >= 10 {
                // BSD `ls -lAT`: month, day, time, year — 4 tokens.
                let stamp = "\(tokens[5]) \(tokens[6]) \(tokens[7]) \(tokens[8])"
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "MMM d HH:mm:ss yyyy"
                mtime = formatter.date(from: stamp)
                nameStartIdx = 9
            } else {
                continue
            }

            // The rest is the filename. For symlinks, `ls` emits ` name -> target`.
            let rest = tokens[nameStartIdx...].joined(separator: " ")
            let (name, linkTarget): (String, String?) = {
                if case .symlink = kind, let arrowRange = rest.range(of: " -> ") {
                    let n = String(rest[..<arrowRange.lowerBound])
                    let t = String(rest[arrowRange.upperBound...])
                    return (n, t)
                } else {
                    return (rest, nil)
                }
            }()

            // Skip `.` and `..` defensively (ls -A should already exclude them).
            if name == "." || name == ".." { continue }
            if name.isEmpty { continue }

            let resolvedKind: SFTPRichEntry.Kind = {
                if case .symlink = kind { return .symlink(target: linkTarget) }
                return kind
            }()

            let fullPath: String
            if parentPath.hasSuffix("/") {
                fullPath = parentPath + name
            } else {
                fullPath = parentPath + "/" + name
            }

            entries.append(SFTPRichEntry(
                name: name,
                path: fullPath,
                kind: resolvedKind,
                sizeBytes: size,
                modifiedAt: mtime
            ))
        }

        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return entries
    }

    // MARK: - SFTP rich listing (Citadel)

    private func listAllEntriesViaSFTP(sftp: SFTPClient, path: String) async throws -> [SFTPRichEntry] {
        let names = try await sftp.listDirectory(atPath: path)
        var entries: [SFTPRichEntry] = []

        for name in names {
            for component in name.components {
                let filename = component.filename
                if filename == "." || filename == ".." { continue }

                let attrs = component.attributes
                let permissions = attrs.permissions ?? 0
                let typeBits = permissions & Self.S_IFMT

                let kind: SFTPRichEntry.Kind
                if typeBits == Self.S_IFDIR {
                    kind = .directory
                } else if typeBits == Self.S_IFLNK {
                    kind = .symlink(target: nil)
                } else if attrs.permissions == nil {
                    // Some servers don't send permissions — fall back to longname leading char.
                    let leading = component.longname.first
                    if leading == "d" {
                        kind = .directory
                    } else if leading == "l" {
                        kind = .symlink(target: nil)
                    } else {
                        kind = .file
                    }
                } else {
                    kind = .file
                }

                let fullPath: String
                if path.hasSuffix("/") {
                    fullPath = path + filename
                } else {
                    fullPath = path + "/" + filename
                }

                let sizeBytes: Int64? = attrs.size.map { Int64($0) }
                let modifiedAt = attrs.accessModificationTime?.modificationTime

                entries.append(SFTPRichEntry(
                    name: filename,
                    path: fullPath,
                    kind: kind,
                    sizeBytes: sizeBytes,
                    modifiedAt: modifiedAt
                ))
            }
        }

        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return entries
    }

    // MARK: - SSH stat

    private func statViaSSH(target: SSHTarget, path: String) async throws -> SFTPRichStat {
        let escaped = shellEscape(path)
        // Try GNU stat first (Linux), fall back to BSD `stat -f` (macOS/FreeBSD).
        // NOTE: separator is the literal string "|" to keep parsing simple even if filenames
        // contain tabs.
        let gnu = "stat -c '%F|%s|%Y' -- \(escaped)"
        let bsd = "stat -f '%HT|%z|%m' -- \(escaped)"
        let cmd = "\(gnu) 2>/dev/null || \(bsd)"

        let result = try await runSSH(target: target, command: cmd)
        guard result.exitCode == 0 else {
            throw SFTPServiceError.commandFailed("stat failed at \(path)")
        }

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.components(separatedBy: "|")
        guard parts.count >= 3 else {
            throw SFTPServiceError.commandFailed("stat parse failed: \(output)")
        }

        let typeStr = parts[0].lowercased()
        let isDirectory = typeStr.contains("directory")
        let isSymlink = typeStr.contains("symbolic link") || typeStr.contains("symlink")
        let size = Int64(parts[1]) ?? 0

        let mtime: Date?
        if let epoch = Int64(parts[2]) {
            mtime = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else {
            mtime = nil
        }

        return SFTPRichStat(
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            sizeBytes: size,
            modifiedAt: mtime
        )
    }

    // MARK: - SFTP stat (Citadel)

    private func statViaSFTP(sftp: SFTPClient, path: String) async throws -> SFTPRichStat {
        let attrs = try await sftp.getAttributes(at: path)
        let permissions = attrs.permissions ?? 0
        let typeBits = permissions & Self.S_IFMT

        let isDirectory = typeBits == Self.S_IFDIR
        let isSymlink = typeBits == Self.S_IFLNK
        let size = Int64(attrs.size ?? 0)
        let modifiedAt = attrs.accessModificationTime?.modificationTime

        return SFTPRichStat(
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            sizeBytes: size,
            modifiedAt: modifiedAt
        )
    }

    // MARK: - SSH read file

    private func readFileViaSSH(target: SSHTarget, path: String, maxBytes: Int) async throws -> Data {
        // Pre-flight: refuse oversize files so we don't allocate a huge buffer.
        let s = try await statViaSSH(target: target, path: path)
        if s.sizeBytes > Int64(maxBytes) {
            throw SFTPServiceError.commandFailed("file too large: \(s.sizeBytes) > \(maxBytes)")
        }

        // Use base64 to stay binary-safe over the SSH text channel.
        let cmd = "cat -- \(shellEscape(path)) | base64"
        let result = try await runSSH(target: target, command: cmd)
        guard result.exitCode == 0 else {
            throw SFTPServiceError.commandFailed("cat failed at \(path)")
        }

        // Strip whitespace before decoding (base64 utility wraps lines).
        let cleaned = result.output.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            throw SFTPServiceError.commandFailed("base64 decode failed for \(path)")
        }
        return data
    }

    // MARK: - SFTP read file (Citadel)

    private func readFileViaSFTP(sftp: SFTPClient, path: String, maxBytes: Int) async throws -> Data {
        // Pre-flight size check.
        let attrs = try await sftp.getAttributes(at: path)
        if let size = attrs.size, size > UInt64(maxBytes) {
            throw SFTPServiceError.commandFailed("file too large: \(size) > \(maxBytes)")
        }

        let file = try await sftp.openFile(filePath: path, flags: .read)
        do {
            let buffer = try await file.readAll()
            try await file.close()
            return Data(buffer.readableBytesView)
        } catch {
            try? await file.close()
            throw error
        }
    }

    // MARK: - SSH write file

    /// Write a file via system `ssh`. NOTE: this is a non-atomic overwrite — `base64 -d > path`
    /// truncates first, so a crash mid-write leaves a partial file. The MVP keeps things simple;
    /// switch to a temp+rename strategy once we have failure-mode tests.
    /// TODO: atomic write via mktemp + mv.
    private func writeFileViaSSH(target: SSHTarget, path: String, data: Data) async throws {
        let b64 = data.base64EncodedString()
        let cmd = "base64 -d > \(shellEscape(path))"
        let result = try await runSSHWithStdin(target: target, command: cmd, stdin: b64)
        guard result.exitCode == 0 else {
            throw SFTPServiceError.commandFailed("write failed at \(path)")
        }
    }

    // MARK: - SFTP write file (Citadel)

    private func writeFileViaSFTP(sftp: SFTPClient, path: String, data: Data) async throws {
        let file = try await sftp.openFile(
            filePath: path,
            flags: [.write, .create, .truncate]
        )
        do {
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await file.write(buffer)
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }
}
