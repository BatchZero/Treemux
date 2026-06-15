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

// MARK: - Pipe drain helper

/// Thread-safe `Data` accumulator. `Pipe.readabilityHandler` fires on a
/// private Foundation queue, so writes can race with the snapshot read in the
/// process's `terminationHandler`.
fileprivate final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
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

    /// Read at most the first `maxBytes` of a remote file. Unlike `readFile`,
    /// this never errors on oversized files — large files yield a `maxBytes`
    /// prefix and stop. Used for content sniffing where we only need a small
    /// window to decide text vs. binary.
    func readPrefix(at path: String, maxBytes: Int) async throws -> Data {
        guard let mode else { throw SFTPServiceError.notConnected }

        switch mode {
        case .ssh(let target):
            return try await readPrefixViaSSH(target: target, path: path, maxBytes: maxBytes)
        case .citadel(_, let sftp):
            return try await readPrefixViaSFTP(sftp: sftp, path: path, maxBytes: maxBytes)
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

    // MARK: - Arbitrary command (used by RemoteGitDiffService)

    /// Runs an arbitrary shell command on the remote, returning its stdout.
    /// In `.ssh` mode, executes via the existing system-ssh path.
    /// In `.citadel` mode, throws — Citadel's API for arbitrary command exec
    /// isn't wired and is not needed by file-browser flows in P1.
    func runCommand(_ command: String, in cwd: String? = nil) async throws -> String {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let full: String
            if let cwd { full = "cd \(Self.shellQuote(cwd)) && \(command)" }
            else { full = command }
            let result = try await runSSH(target: target, command: full)
            guard result.exitCode == 0 else {
                throw SFTPServiceError.commandFailed("exit \(result.exitCode): \(result.output)")
            }
            return result.output
        case .citadel:
            throw SFTPServiceError.commandFailed("runCommand not supported in Citadel password-auth mode")
        }
    }

    /// Whether the active connection can run arbitrary shell commands (system-SSH
    /// path). Citadel password-auth cannot, so callers fall back to per-dir BFS.
    var supportsBulkCommand: Bool {
        if case .ssh = mode { return true }
        return false
    }

    /// Bulk-fetch a directory tree in one SSH round-trip. Only valid on the
    /// system-SSH path (`supportsBulkCommand == true`). Returns each directory's
    /// children keyed by parent path, plus the set of directories whose listing
    /// was capped at `entryCap`.
    func listTreeViaCommand(root: String, maxDepth: Int, entryCap: Int)
        async throws -> (childrenByPath: [String: [SFTPRichEntry]], truncated: Set<String>) {
        let output = try await runCommand(Self.bulkListCommand(maxDepth: maxDepth), in: root)
        var grouped = Self.parseRecursiveListing(output: output, root: root)
        var truncated: Set<String> = []
        for (dir, entries) in grouped where entries.count > entryCap {
            grouped[dir] = Array(entries.prefix(entryCap))
            truncated.insert(dir)
        }
        return (grouped, truncated)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    struct SSHResult {
        let exitCode: Int32
        let output: String
    }

    private func runSSH(target: SSHTarget, command: String) async throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.sshArgs(target: target, command: command)
        return try await Self.runProcessAndCaptureOutput(process)
    }

    private func shellEscape(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - SSH stdin helper

    /// Like `runSSH(target:command:)` but feeds `stdin` to the remote command's standard input.
    private func runSSHWithStdin(target: SSHTarget, command: String, stdin: String) async throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.sshArgs(target: target, command: command)
        let stdinData = stdin.data(using: .utf8) ?? Data()
        return try await Self.runProcessAndCaptureOutput(process, stdin: stdinData)
    }

    private static func sshArgs(target: SSHTarget, command: String) -> [String] {
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
        return args
    }

    /// Runs `process` to completion and returns its stdout + exit code.
    ///
    /// Drains stdout/stderr incrementally as the child writes. Darwin's pipe
    /// buffer is ~16 KB, so a child producing more than that on either stream
    /// blocks on write if nobody reads — with the previous "read in
    /// terminationHandler" approach the process then never terminated, the
    /// callback never fired, and the awaiting Task hung forever. Manifested
    /// as a stuck spinner when reading any remote file larger than the buffer
    /// over SSH (`cat | base64` output exceeds 16 KB at ~12 KB of source).
    ///
    /// Optionally writes `stdin` to the child and closes it. The write runs
    /// off the cooperative pool so a backpressured ssh process can't stall
    /// the awaiting Task while a large payload drains.
    static func runProcessAndCaptureOutput(_ process: Process, stdin: Data? = nil) async throws -> SSHResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        } else {
            stdinPipe = nil
        }

        let stdoutBuffer = DataAccumulator()
        let stderrBuffer = DataAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil }
            else { stdoutBuffer.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { fh.readabilityHandler = nil }
            else { stderrBuffer.append(chunk) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                // Detach handlers and grab any final bytes synchronously. The
                // child's write end is closed by the kernel on exit, so these
                // reads see EOF promptly even if a chunk arrived between the
                // last readabilityHandler call and the termination callback.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                let output = String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? ""
                continuation.resume(returning: SSHResult(exitCode: process.terminationStatus, output: output))
            }
            do {
                try process.run()
                if let stdin, let stdinPipe {
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }
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

        return Self.parseListing(output: result.output, parentPath: path)
    }

    /// Parse `ls -lA` style output. Auto-detects whether the timestamp is a single epoch field
    /// (Linux `--time-style=+%s`) or 4 BSD fields (`Mon DD HH:MM:SS YYYY`).
    /// Exposed at internal scope (and as a static function) so unit tests can drive it directly.
    static func parseListing(output: String, parentPath: String) -> [SFTPRichEntry] {
        var entries: [SFTPRichEntry] = []

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("total ") { continue }

            // Tokenize by whitespace; collapse runs.
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Layout: tokens[0]=perms, [1]=links, [2]=owner, [3]=group, [4]=size, [5..]=date+name.
            // GNU `--time-style=+%s`: epoch is one field, so a single-word filename takes 7 tokens.
            // BSD `ls -lAT`:           date is four fields, so a single-word filename takes 10 tokens.
            // The lower bound (7) is the minimum for either format.
            guard tokens.count >= 7 else { continue }

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

    // MARK: - Recursive (bulk) listing helpers

    /// Builds the portable bulk-listing command run on the system-SSH path.
    /// One `find` enumerates entries to `maxDepth`, then `ls -ld` stats each in
    /// a batched `-exec … +`. GNU `--time-style=+%s` is tried first; on BSD/macOS
    /// (which lacks it) the `||` fallback uses `ls -ldnT`. `-n` keeps owner/group
    /// numeric so they never introduce spaces that would break tokenization.
    /// The leading `cd <root>` is supplied by `runCommand(_:in:)`, so names come
    /// back relative (`./sub/file`).
    static func bulkListCommand(maxDepth: Int) -> String {
        let sel = "\\( -type d -o -type f -o -type l \\)"
        let gnu = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldn --time-style=+%s {} +"
        let bsd = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldnT {} +"
        return "\(gnu) 2>/dev/null || \(bsd)"
    }

    /// Parses the recursive `ls -ld` output produced by `bulkListCommand`.
    /// Names arrive as paths relative to `root` (`./a/b.txt`); each entry is
    /// reassembled into an absolute path and grouped under its parent directory.
    /// Each group is sorted directories-first, then case-insensitive by name —
    /// matching `RemoteFileBrowserDataSource.listDirectory`'s ordering.
    static func parseRecursiveListing(output: String, root: String) -> [String: [SFTPRichEntry]] {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        var grouped: [String: [SFTPRichEntry]] = [:]

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("total ") { continue }

            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 7 else { continue }

            let perms = tokens[0]
            guard let typeChar = perms.first else { continue }
            let baseKind: SFTPRichEntry.Kind
            switch typeChar {
            case "d": baseKind = .directory
            case "l": baseKind = .symlink(target: nil)
            default:  baseKind = .file
            }

            guard let size = Int64(tokens[4]) else { continue }

            let mtime: Date?
            let nameStartIdx: Int
            if let epoch = Int64(tokens[5]) {
                mtime = Date(timeIntervalSince1970: TimeInterval(epoch))
                nameStartIdx = 6
            } else if tokens.count >= 10 {
                let stamp = "\(tokens[5]) \(tokens[6]) \(tokens[7]) \(tokens[8])"
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "MMM d HH:mm:ss yyyy"
                mtime = fmt.date(from: stamp)
                nameStartIdx = 9
            } else {
                continue
            }

            let rest = tokens[nameStartIdx...].joined(separator: " ")
            let (relName, linkTarget): (String, String?) = {
                if case .symlink = baseKind, let arrow = rest.range(of: " -> ") {
                    return (String(rest[..<arrow.lowerBound]), String(rest[arrow.upperBound...]))
                }
                return (rest, nil)
            }()

            var rel = relName
            if rel.hasPrefix("./") { rel.removeFirst(2) }
            if rel.isEmpty || rel == "." || rel == ".." { continue }

            let absolutePath = normalizedRoot + "/" + rel
            let name = (absolutePath as NSString).lastPathComponent
            let parent = (absolutePath as NSString).deletingLastPathComponent

            let kind: SFTPRichEntry.Kind = {
                if case .symlink = baseKind { return .symlink(target: linkTarget) }
                return baseKind
            }()

            grouped[parent, default: []].append(
                SFTPRichEntry(name: name, path: absolutePath, kind: kind, sizeBytes: size, modifiedAt: mtime)
            )
        }

        for (parent, entries) in grouped {
            grouped[parent] = entries.sorted { a, b in
                let aDir = a.isDirectory, bDir = b.isDirectory
                if aDir != bDir { return aDir }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return grouped
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

    // MARK: - Read prefix (sniff)

    private func readPrefixViaSSH(target: SSHTarget, path: String, maxBytes: Int) async throws -> Data {
        // `head -c` bounds the read at the source so we don't transfer more
        // bytes than necessary. base64 keeps the channel binary-safe.
        let cmd = "head -c \(maxBytes) -- \(shellEscape(path)) | base64"
        let result = try await runSSH(target: target, command: cmd)
        guard result.exitCode == 0 else {
            throw SFTPServiceError.commandFailed("head failed at \(path)")
        }
        let cleaned = result.output.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            throw SFTPServiceError.commandFailed("base64 decode failed for \(path)")
        }
        return data
    }

    private func readPrefixViaSFTP(sftp: SFTPClient, path: String, maxBytes: Int) async throws -> Data {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        do {
            let length = UInt32(min(maxBytes, Int(UInt32.max)))
            let buffer = try await file.read(from: 0, length: length)
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
