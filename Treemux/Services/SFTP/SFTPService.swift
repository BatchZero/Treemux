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
    case connectionLost(String)
    case notFound(String)
    case atomicOverwriteUnsupported
    case commandFailed(String)
    case commandTimedOut(TimeInterval)

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
        case .connectionLost(let detail):
            return "SSH connection lost: \(detail)"
        case .notFound(let path):
            return "Remote item not found: \(path)"
        case .atomicOverwriteUnsupported:
            return String(localized: "Remote server cannot safely replace this file.")
        case .commandFailed(let detail):
            return "SSH command failed: \(detail)"
        case .commandTimedOut(let seconds):
            return "SSH command timed out after \(Int(seconds))s"
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

/// Lets exactly one of several racing callbacks (process termination, a
/// timeout, or a launch failure) resume a `CheckedContinuation`. The first
/// `claim()` returns `true`; every later one returns `false`, so the
/// continuation is resumed once and only once.
fileprivate final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
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
    var isConnected: Bool {
        switch mode {
        case .none: false
        case .ssh: true
        case .citadel(let client, let sftp): client.isConnected && sftp.isActive
        }
    }

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

    /// Returns target metadata for transfer sizing, following a symbolic link.
    func transferTargetStat(_ path: String) async throws -> SFTPRichStat {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            return try await statViaSSH(target: target, path: path, followSymbolicLinks: true)
        case .citadel(_, let sftp):
            return try await statViaSFTP(sftp: sftp, path: path)
        }
    }

    func canonicalDirectoryIdentity(_ path: String) async throws -> String {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(
                target: target,
                command: Self.canonicalDirectoryIdentityCommand(path: path)
            )
            guard result.exitCode == 0,
                  let identity = Self.parseCanonicalDirectoryIdentityOutput(result.output),
                  !identity.isEmpty else {
                if result.exitCode == 255 {
                    throw SFTPServiceError.connectionLost(
                        "cannot resolve directory at \(path)"
                    )
                }
                throw SFTPServiceError.commandFailed("cannot resolve directory at \(path)")
            }
            return identity
        case .citadel(_, let sftp):
            return try await sftp.getRealPath(atPath: path)
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

    /// Create a directory at `path`. Fails if it already exists (no `-p`
    /// semantics), matching the local `FileBrowserDataSource` implementation.
    func createDirectory(at path: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(target: target, command: Self.mkdirCommand(path: path))
            guard result.exitCode == 0 else {
                throw Self.transferCommandFailure(
                    exitCode: result.exitCode,
                    detail: "mkdir failed at \(path)"
                )
            }
        case .citadel(_, let sftp):
            try await sftp.createDirectory(atPath: path)
        }
    }

    /// Create an empty file at `path`. Fails if it already exists.
    func createFile(at path: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(target: target, command: Self.touchNoclobberCommand(path: path))
            guard result.exitCode == 0 else {
                throw SFTPServiceError.commandFailed("create file failed at \(path)")
            }
        case .citadel(_, let sftp):
            // Atomic exclusive create (SSH_FXF_EXCL): the server fails the open if the
            // path already exists, so there is no check-then-truncate race and no
            // silent overwrite. Mirrors the SSH path's `set -C` noclobber guarantee.
            let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .forceCreate])
            try await file.close()
        }
    }

    func readTransferChunk(at path: String, offset: Int64, length: Int) async throws -> Data {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(
                target: target,
                command: Self.transferReadCommand(path: path, offset: offset, length: length)
            )
            guard result.exitCode == 0 else {
                throw Self.transferCommandFailure(
                    exitCode: result.exitCode,
                    detail: "chunk read failed at \(path)"
                )
            }
            let cleaned = result.output
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let data = Data(base64Encoded: cleaned) else {
                throw SFTPServiceError.commandFailed("base64 decode failed for \(path)")
            }
            return data
        case .citadel(_, let sftp):
            let file = try await sftp.openFile(filePath: path, flags: .read)
            do {
                let buffer = try await file.read(
                    from: UInt64(offset),
                    length: UInt32(min(length, Int(UInt32.max)))
                )
                try await file.close()
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    func createTransferTemporaryFile(at path: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(
                target: target,
                command: Self.transferCreateCommand(path: path)
            )
            guard result.exitCode == 0 else {
                throw Self.transferCommandFailure(
                    exitCode: result.exitCode,
                    detail: "temporary file create failed at \(path)"
                )
            }
        case .citadel(_, let sftp):
            let file = try await sftp.openFile(
                filePath: path,
                flags: [.write, .create, .forceCreate]
            )
            try await file.close()
        }
    }

    func writeTransferChunk(_ data: Data, at path: String, offset: Int64) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSHWithStdin(
                target: target,
                command: Self.transferWriteCommand(path: path, offset: offset),
                stdin: data.base64EncodedString()
            )
            guard result.exitCode == 0 else {
                throw Self.transferCommandFailure(
                    exitCode: result.exitCode,
                    detail: "chunk write failed at \(path)"
                )
            }
        case .citadel(_, let sftp):
            let file = try await sftp.openFile(filePath: path, flags: .write)
            do {
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await file.write(buffer, at: UInt64(offset))
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    func replaceTransferItem(at path: String, withTemporaryItemAt temporaryPath: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(
                target: target,
                command: Self.transferReplaceCommand(
                    temporaryPath: temporaryPath,
                    destinationPath: path
                )
            )
            guard result.exitCode == 0 else {
                throw Self.transferCommandFailure(
                    exitCode: result.exitCode,
                    detail: "temporary replace failed at \(path)"
                )
            }
        case .citadel(let client, _):
            do {
                try await Self.atomicallyReplaceCitadelItem(
                    temporaryPath: temporaryPath,
                    destinationPath: path,
                    execute: { command in
                        _ = try await client.executeCommand(
                            command,
                            mergeStreams: true,
                            inShell: true
                        )
                    }
                )
            } catch {
                if !client.isConnected {
                    throw SFTPServiceError.connectionLost("atomic overwrite failed at \(path)")
                }
                throw SFTPServiceError.atomicOverwriteUnsupported
            }
        }
    }

    func removeTransferItem(at path: String) async throws {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let result = try await runSSH(target: target, command: "rm -rf -- \(Self.shellEscape(path))")
            guard result.exitCode == 0 else {
                throw Self.transferCommandFailure(
                    exitCode: result.exitCode,
                    detail: "remove failed at \(path)"
                )
            }
        case .citadel(_, let sftp):
            let attributes = try await sftp.getAttributes(at: path)
            let typeBits = (attributes.permissions ?? 0) & Self.S_IFMT
            if typeBits == Self.S_IFDIR {
                let children = try await listAllEntriesViaSFTP(sftp: sftp, path: path)
                for child in children {
                    try await removeTransferItem(at: child.path)
                }
                try await sftp.rmdir(at: path)
            } else {
                try await sftp.remove(at: path)
            }
        }
    }

    nonisolated static func transferReadCommand(path: String, offset: Int64, length: Int) -> String {
        let blockSize: Int64 = 64 * 1024
        let positiveOffset = max(0, offset)
        let skipBlocks = positiveOffset / blockSize
        let remainder = positiveOffset % blockSize
        let byteCount = max(0, Int64(length))
        let blockCount = max(1, (remainder + byteCount + blockSize - 1) / blockSize)
        var command = "dd if=\(shellEscape(path)) bs=\(blockSize) skip=\(skipBlocks) "
            + "count=\(blockCount) 2>/dev/null"
        if remainder > 0 {
            command += " | tail -c +\(remainder + 1)"
        }
        return command + " | head -c \(byteCount) | base64"
    }

    nonisolated static func transferWriteCommand(path: String, offset: Int64) -> String {
        let blockSize: Int64 = 64 * 1024
        let positiveOffset = max(0, offset)
        let seekBlocks = positiveOffset / blockSize
        let remainder = positiveOffset % blockSize
        let destination = shellEscape(path)
        let writer = "dd of=\(destination) bs=\(blockSize) seek=\(seekBlocks) conv=notrunc 2>/dev/null"
        guard remainder > 0 else { return "base64 -d | \(writer)" }
        return "{ dd if=\(destination) bs=\(blockSize) skip=\(seekBlocks) count=1 2>/dev/null "
            + "| head -c \(remainder); base64 -d; } | \(writer)"
    }

    nonisolated static func transferCreateCommand(path: String) -> String {
        "( set -C; umask 077; : > \(shellEscape(path)) )"
    }

    nonisolated static func transferReplaceCommand(
        temporaryPath: String,
        destinationPath: String
    ) -> String {
        "mv -f -- \(shellEscape(temporaryPath)) \(shellEscape(destinationPath))"
    }

    nonisolated static func transferCommandFailure(
        exitCode: Int32,
        detail: String
    ) -> SFTPServiceError {
        exitCode == 255 ? .connectionLost(detail) : .commandFailed(detail)
    }

    nonisolated static func transferStatFailure(exitCode: Int32, path: String) -> SFTPServiceError {
        switch exitCode {
        case 44: .notFound(path)
        case 255: .connectionLost("stat failed at \(path)")
        default: .commandFailed("stat failed at \(path)")
        }
    }

    nonisolated static func transferStatCommand(
        path: String,
        followSymbolicLinks: Bool
    ) -> String {
        let escaped = shellEscape(path)
        let followOption = followSymbolicLinks ? "-L " : ""
        let gnu = "stat \(followOption)-c '%F|%s|%Y' -- \(escaped)"
        let bsd = "stat \(followOption)-f '%HT|%z|%m' -- \(escaped)"
        let missingCheck = "[ ! -e \(escaped) ] && [ ! -L \(escaped) ] && exit 44"
        return "\(missingCheck); \(gnu) 2>/dev/null || \(bsd)"
    }

    nonisolated static func atomicallyReplaceCitadelItem(
        temporaryPath: String,
        destinationPath: String,
        execute: (String) async throws -> Void
    ) async throws {
        try await execute(transferReplaceCommand(
            temporaryPath: temporaryPath,
            destinationPath: destinationPath
        ))
    }

    // MARK: - Arbitrary command (used by RemoteGitDiffService)

    /// Runs an arbitrary shell command on the remote, returning its stdout.
    /// In `.ssh` mode, executes via the existing system-ssh path.
    /// In `.citadel` mode, throws — Citadel's API for arbitrary command exec
    /// isn't wired and is not needed by file-browser flows in P1.
    func runCommand(_ command: String, in cwd: String? = nil, timeout: TimeInterval? = nil) async throws -> String {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let full: String
            if let cwd { full = "cd \(Self.shellQuote(cwd)) && \(command)" }
            else { full = command }
            let result = try await runSSH(target: target, command: full, timeout: timeout)
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
        let output = try await runCommand(
            Self.bulkListCommand(maxDepth: maxDepth), in: root, timeout: Self.listingCommandTimeout)
        let (listingOut, probeOut) = Self.splitSymlinkProbeOutput(output)
        // `runCommand(_:in:)` supplies the leading `cd <root>`, so the probe's
        // `find .` names are ./-relative to `root`.
        let resolutions = Self.parseSymlinkProbe(probeOut, parentPath: root)
        var grouped = Self.parseRecursiveListing(
            output: listingOut,
            root: root,
            symlinkResolutions: resolutions
        )
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

    // MARK: - Recursive name search

    /// One-round-trip recursive name search. `find` matches the glob; the
    /// `-exec sh -c` classifies each hit as `d`/`f` portably (GNU + BSD), and
    /// `head` caps the result count (and stops `find` early via SIGPIPE).
    ///
    /// - Parameter includeHidden: When `false`, a portable prune
    ///   (`-name '.?*' -prune -o ...`) is inserted so `find` neither descends
    ///   into nor reports any dotted entry — mirroring the local walk's
    ///   hidden-directory pruning (FIX I1), so remote search can't surface a
    ///   non-hidden leaf living under a hidden directory (e.g. `.git/config`)
    ///   when "Show Hidden Files" is off. When `true`, the command is emitted
    ///   exactly as before (no prune).
    static func recursiveSearchCommand(root: String, query: String,
                                       maxDepth: Int, maxResults: Int, includeHidden: Bool) -> String {
        let escRoot = shellEscape(root)
        let glob = shellEscape("*\(query)*")
        let classify = "-exec sh -c 'for p; do if [ -d \"$p\" ]; then printf \"d %s\\n\" \"$p\"; "
            + "else printf \"f %s\\n\" \"$p\"; fi; done' _ {} +"
        if includeHidden {
            return "find \(escRoot) -maxdepth \(maxDepth) -iname \(glob) 2>/dev/null "
                + classify + " | head -n \(maxResults)"
        }
        // `-name '.?*' ! -path <escRoot> -prune -o \( -iname ... \)`: for each
        // entry, `find` evaluates left-to-right; `-o` has the lowest
        // precedence, so this splits into two implicit-AND groups —
        // `-name '.?*' ! -path <escRoot> -prune` and `-iname glob -exec ... +`
        // (grouped with `\( \)` for clarity/safety). A dotted entry matches
        // the left group; `-prune`'s side effect stops `find` from descending
        // into it (if it's a directory) and its own truthiness short-circuits
        // the `-o`, so the right group — the classify+print — never runs for
        // it. A non-dotted entry fails the left group, falling through to the
        // right group as before.
        //
        // `! -path <escRoot>` exempts the search ROOT itself from the prune:
        // `find` evaluates its own starting pathname (the exact string passed
        // as the start argument) against every predicate just like any other
        // entry, so if the root itself is a dotted directory (e.g. an SSH
        // browse root of `/home/u/.config`), `-name '.?*'` would match it and
        // `-prune` would discard the whole tree before any children are ever
        // visited — silently returning zero results even though matches
        // exist. Reusing `escRoot` (the same escaped value passed as the
        // start argument) for `-path` guarantees the exemption can never
        // diverge from the actual root, while dotted DESCENDANTS at any depth
        // are still pruned as before.
        return "find \(escRoot) -maxdepth \(maxDepth) -name '.?*' ! -path \(escRoot) -prune -o "
            + "\\( -iname \(glob) " + classify + " \\) 2>/dev/null | head -n \(maxResults)"
    }

    /// Parses `d <path>` / `f <path>` lines from `recursiveSearchCommand`.
    static func parseFindResults(_ output: String) -> [SFTPRichEntry] {
        var out: [SFTPRichEntry] = []
        for line in output.components(separatedBy: "\n") {
            guard line.count > 2 else { continue }
            let typeChar = line.first!
            guard typeChar == "d" || typeChar == "f" else { continue }
            let path = String(line.dropFirst(2))
            guard !path.isEmpty else { continue }
            let name = (path as NSString).lastPathComponent
            out.append(SFTPRichEntry(
                name: name, path: path,
                kind: typeChar == "d" ? .directory : .file,
                sizeBytes: nil, modifiedAt: nil))
        }
        return out
    }

    func searchNames(root: String, query: String,
                     maxDepth: Int, maxResults: Int, includeHidden: Bool) async throws -> [SFTPRichEntry] {
        guard let mode else { throw SFTPServiceError.notConnected }
        switch mode {
        case .ssh(let target):
            let cmd = Self.recursiveSearchCommand(
                root: root, query: query, maxDepth: maxDepth, maxResults: maxResults, includeHidden: includeHidden)
            let result = try await runSSH(target: target, command: cmd, timeout: Self.listingCommandTimeout)
            // `head` closing the pipe yields exit 141 (SIGPIPE); treat any output
            // as success rather than gating on exitCode.
            return Self.parseFindResults(result.output)
        case .citadel:
            // No arbitrary exec on the Citadel password path.
            throw SFTPServiceError.commandFailed(
                "Recursive search requires key-based (system SSH) auth")
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
        let escapedPath = Self.shellEscape(path)
        let result = try await runSSH(
            target: target, command: "ls -1pa \(escapedPath)", timeout: Self.listingCommandTimeout)

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

    private func runSSH(target: SSHTarget, command: String, timeout: TimeInterval? = nil) async throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.sshArgs(target: target, command: command)
        return try await Self.runProcessAndCaptureOutput(process, timeout: timeout)
    }

    private static func shellEscape(_ path: String) -> String {
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

    /// Internal (not private) so tests can assert the mux options are wired in.
    static func sshArgs(target: SSHTarget, command: String) -> [String] {
        SSHMultiplexing.sshArguments(target: target, command: command)
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
    static func runProcessAndCaptureOutput(_ process: Process, stdin: Data? = nil, timeout: TimeInterval? = nil) async throws -> SSHResult {
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
            // `terminationHandler`, the timeout, and a launch failure all race
            // to resume the continuation; the guard ensures exactly one wins.
            let resume = ResumeGuard()

            // Optional wall-clock ceiling. A stalled remote command (a huge
            // listing, a dead connection) would otherwise leave the awaiting
            // Task — and the file browser's spinner — hung forever. On expiry we
            // kill the child and surface a timeout error.
            var timeoutItem: DispatchWorkItem?
            if let timeout {
                let item = DispatchWorkItem {
                    guard resume.claim() else { return }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    if process.isRunning { process.terminate() }
                    continuation.resume(throwing: SFTPServiceError.commandTimedOut(timeout))
                }
                timeoutItem = item
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: item)
            }

            process.terminationHandler = { _ in
                guard resume.claim() else { return }
                timeoutItem?.cancel()
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
                guard resume.claim() else { return }
                timeoutItem?.cancel()
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
        let escapedPath = Self.shellEscape(path)

        // Try GNU coreutils first (Linux). If that fails (likely macOS/BSD), retry with -T.
        let gnuCmd = "ls -lA --time-style=+%s -- \(escapedPath)"
        let bsdCmd = "ls -lAT -- \(escapedPath)"
        let listing = "( \(gnuCmd) 2>/dev/null || \(bsdCmd) )"
        // Capture the listing's exit code into `__tmx_rc` immediately, before the
        // probe runs, then `exit $__tmx_rc` at the end so the overall exit code
        // reflects ONLY the listing. The probe (including its `cd`) runs
        // best-effort after that capture — a failed `cd` just yields an empty
        // probe set (graceful), it can never mask a listing failure or discard a
        // successful listing. cd into the dir so the probe's `find .` emits
        // ./-relative names we can resolve against `path`. The listing itself
        // still uses the absolute path.
        let probe = Self.symlinkDirProbeFragment(maxDepth: 1)
        let combined = "\(listing); __tmx_rc=$?; cd \(escapedPath) 2>/dev/null && \(probe); exit $__tmx_rc"

        let result = try await runSSH(target: target, command: combined, timeout: Self.listingCommandTimeout)
        guard result.exitCode == 0 else {
            if result.exitCode == 255 {
                throw SFTPServiceError.connectionLost("ls failed at \(path)")
            }
            throw SFTPServiceError.commandFailed("ls failed at \(path)")
        }

        let (listingOut, probeOut) = Self.splitSymlinkProbeOutput(result.output)
        let resolutions = Self.parseSymlinkProbe(probeOut, parentPath: path)
        return Self.parseListing(
            output: listingOut,
            parentPath: path,
            symlinkResolutions: resolutions
        )
    }

    /// Legacy text marker retained only for parsing cached/test output produced
    /// before the NUL-framed probe protocol was introduced.
    static let symlinkProbeMarker = "@@TMX_SYMDIRS@@"
    static let symlinkProbeFrame = "\0TMX_SYMLINK_PROBE\0"

    static func splitSymlinkProbeOutput(_ output: String) -> (listing: String, probe: String) {
        if let range = output.range(of: symlinkProbeFrame) {
            return (
                String(output[..<range.lowerBound]),
                String(output[range.upperBound...])
            )
        }
        let sections = output.components(separatedBy: symlinkProbeMarker)
        return (sections.first ?? output, sections.count > 1 ? sections[1] : "")
    }

    /// Parses the probe section: one path per line, each a symlink whose target is
    /// a directory. When `parentPath` is non-nil, entries are `./`-relative and are
    /// resolved against it (bulk form); otherwise they are already absolute.
    static func parseSymlinkDirProbe(_ output: String, parentPath: String?) -> Set<String> {
        let base = parentPath.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var set: Set<String> = []
        for raw in output.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let base {
                if line.hasPrefix("./") { line.removeFirst(2) }
                if line.isEmpty { continue }
                set.insert(base + "/" + line)
            } else {
                set.insert(line)
            }
        }
        return set
    }

    /// Parses tab-delimited probe records. The first field is the outcome, the
    /// second is the displayed path, and directory/unresolved records carry a
    /// third canonical identity or reason field.
    static func parseSymlinkProbe(
        _ output: String,
        parentPath: String?
    ) -> [String: SymlinkTargetResolution] {
        let base = parentPath.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var results: [String: SymlinkTargetResolution] = [:]

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2 else { continue }
            let isHexEncoded = fields[0].hasPrefix("H")
            let outcome = isHexEncoded ? String(fields[0].dropFirst()) : fields[0]
            guard var path = isHexEncoded ? decodeHexString(fields[1]) : fields[1] else { continue }
            if let base {
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard !path.isEmpty else { continue }
                path = base + "/" + path
            }

            switch outcome {
            case "D" where fields.count >= 3 && !fields[2].isEmpty:
                let identity = isHexEncoded ? decodeHexString(fields[2]) : fields[2]
                guard let identity, !identity.isEmpty else { continue }
                results[path] = .directory(canonicalIdentity: identity)
            case "F":
                results[path] = .file
            case "B":
                results[path] = .broken
            case "I":
                results[path] = .inaccessible
            case "U":
                results[path] = .unresolved(reason: fields.count >= 3 ? fields[2] : nil)
            default:
                continue
            }
        }
        return results
    }

    private static func decodeHexString(_ encoded: String) -> String? {
        guard encoded.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.count / 2)
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: 2)
            guard let byte = UInt8(encoded[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(data: Data(bytes), encoding: .utf8)
    }

    /// Builds a shell command that resolves `path` and writes its exact UTF-8
    /// bytes as a hex record. The sentinel preserves trailing newlines through
    /// command substitution before the resolver's terminating newline is removed.
    static func canonicalDirectoryIdentityCommand(path: String) -> String {
        let escaped = shellEscape(path)
        return """
        if identity=$(
          (realpath -- \(escaped) 2>/dev/null || (cd -P \(escaped) 2>/dev/null && pwd -P)) && printf '\\001'
        ); then
          identity=${identity%?}
          identity=${identity%
        }
          printf 'H'
          printf '%s' "$identity" | od -An -v -tx1 | tr -d ' \\n'
          printf '\\n'
        else
          exit 1
        fi
        """
    }

    /// Decodes one canonical identity hex record without modifying its bytes.
    static func parseCanonicalDirectoryIdentityOutput(_ output: String) -> String? {
        guard output.last == "\n" else { return nil }
        let record = output.dropLast()
        guard record.first == "H" else { return nil }
        return decodeHexString(String(record.dropFirst()))
    }

    /// Shell fragment that emits a NUL-delimited frame followed by hex-encoded
    /// symlink records. `find -exec` passes names as arguments, so tabs and
    /// newlines cannot split records before encoding.
    static func symlinkDirProbeFragment(maxDepth: Int) -> String {
        let script = """
        hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
        for l do
          lh=$(hex "$l")
          if [ -d "$l/" ]; then
            if [ ! -r "$l/" ] || [ ! -x "$l/" ]; then
              printf 'HI\t%s\n' "$lh"
            else
              if c=$(
                (realpath -- "$l" 2>/dev/null || (cd -P "$l" 2>/dev/null && pwd -P)) && printf '\\001'
              ); then
                c=${c%?}
                c=${c%
        }
                if [ -n "$c" ]; then
                  printf 'HD\t%s\t%s\n' "$lh" "$(hex "$c")"
                else
                  printf 'HU\t%s\n' "$lh"
                fi
              else
                printf 'HU\t%s\n' "$lh"
              fi
            fi
          elif [ -e "$l" ]; then
            printf 'HF\t%s\n' "$lh"
          else
            error=$(LC_ALL=C ls -Ld "$l/" 2>&1 >/dev/null)
            case "$error" in
              *'Permission denied'*|*'Operation not permitted'*) printf 'HI\t%s\n' "$lh" ;;
              *) printf 'HB\t%s\n' "$lh" ;;
            esac
          fi
        done
        """
        return "printf '\\000TMX_SYMLINK_PROBE\\000'; "
            + "find . -mindepth 1 -maxdepth \(maxDepth) -type l "
            + "-exec sh -c \(shellQuote(script)) sh {} + 2>/dev/null"
    }

    /// Parse `ls -lA` style output. Auto-detects whether the timestamp is a single epoch field
    /// (Linux `--time-style=+%s`) or 4 BSD fields (`Mon DD HH:MM:SS YYYY`).
    /// Exposed at internal scope (and as a static function) so unit tests can drive it directly.
    static func parseListing(
        output: String,
        parentPath: String,
        symlinkDirPaths: Set<String> = [],
        symlinkResolutions: [String: SymlinkTargetResolution] = [:]
    ) -> [SFTPRichEntry] {
        var entries: [SFTPRichEntry] = []
        // Hoisted out of the loop — see `parseRecursiveListing` for why per-line
        // `DateFormatter` allocation is a performance problem on big listings.
        let bsdFormatter = makeBSDDateFormatter()

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
                mtime = bsdFormatter.date(from: stamp)
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

            let resolution = symlinkResolutions[fullPath]
                ?? (symlinkDirPaths.contains(fullPath)
                    ? .directory(canonicalIdentity: fullPath)
                    : .unresolved(reason: nil))
            entries.append(SFTPRichEntry(
                name: name,
                path: fullPath,
                kind: resolvedKind,
                sizeBytes: size,
                modifiedAt: mtime,
                symlinkTargetResolution: resolution
            ))
        }

        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return entries
    }

    /// Builds a `DateFormatter` for BSD `ls -lAT` timestamps
    /// (`Mon DD HH:MM:SS YYYY`). Callers create one per parse and reuse it
    /// across lines — allocating one per entry was a real perf cost on large
    /// remote listings.
    static func makeBSDDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm:ss yyyy"
        return f
    }

    // MARK: - Recursive (bulk) listing helpers

    /// Builds the portable bulk-listing command run on the system-SSH path.
    /// One `find` enumerates entries to `maxDepth`, then `ls -ld` stats each in
    /// a batched `-exec … +`. GNU `--time-style=+%s` is tried first; on BSD/macOS
    /// (which lacks it) the `||` fallback uses `ls -ldnT`. `-n` keeps owner/group
    /// numeric so they never introduce spaces that would break tokenization.
    /// The leading `cd <root>` is supplied by `runCommand(_:in:)`, so names come
    /// back relative (`./sub/file`).
    /// Hard upper bound on lines (≈ entries) the bulk tree listing transfers
    /// and parses in one fetch, independent of the remote tree's real size. A
    /// safety valve against catastrophically large remote directories: without
    /// it the client streamed and parsed every entry (hundreds of thousands on
    /// a big tree) before the per-directory `entryCap` truncated anything, so
    /// the file browser just spun forever. Expanding a node re-lists it, so a
    /// capped fetch is never the last word on a directory's contents.
    static let bulkListMaxEntries = 50_000

    /// Wall-clock ceiling for directory-listing SSH commands. Listings are
    /// bounded by `bulkListMaxEntries`, so they should return quickly; this
    /// converts a stalled connection or pathological remote FS into an error
    /// banner instead of an infinite spinner. File *reads* deliberately pass no
    /// timeout — a large transfer can legitimately exceed this.
    static let listingCommandTimeout: TimeInterval = 25

    static func bulkListCommand(maxDepth: Int, maxEntries: Int = bulkListMaxEntries) -> String {
        let sel = "\\( -type d -o -type f -o -type l \\)"
        let gnu = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldn --time-style=+%s {} +"
        let bsd = "find . -mindepth 1 -maxdepth \(maxDepth) \(sel) -exec ls -ldnT {} +"
        // Wrap the GNU||BSD listing in a subshell and pipe through `head` so the
        // cap applies whichever branch runs. `head` closing the pipe also makes
        // `find` stop early via SIGPIPE, so the server doesn't keep walking the
        // tree after the cap is reached.
        let listing = "( \(gnu) 2>/dev/null || \(bsd) ) | head -n \(maxEntries)"
        // Capture the listing's exit code before running the best-effort probe,
        // then exit with the captured code — see the analogous comment in
        // `listAllEntriesViaSSH`. `runCommand(_:in:)` prepends `cd <root> && `,
        // so the full command is `cd root && LISTING; __tmx_rc=$?; PROBE; exit
        // $__tmx_rc`; shell precedence makes `__tmx_rc` capture the exit of
        // `(cd root && LISTING)`. `__tmx_rc` preserves the pre-existing exit
        // semantics of that expression rather than adding new guarantees: since
        // `LISTING` is piped through `head` without `pipefail`, `__tmx_rc`
        // reliably reflects a failed `cd root` (which short-circuits the `&&`
        // before the pipe even runs), but an inner `ls`/`find` failure inside
        // the pipe is generally masked by `head`'s own success. Either way, the
        // probe runs strictly after this capture, so it can never mask or
        // overwrite whatever `__tmx_rc` already holds.
        return "\(listing); __tmx_rc=$?; \(symlinkDirProbeFragment(maxDepth: maxDepth)); exit $__tmx_rc"
    }

    /// Builds the remote command that creates a directory, failing if it
    /// already exists (plain `mkdir`, no `-p`).
    static func mkdirCommand(path: String) -> String {
        "mkdir -- \(Self.shellEscape(path))"
    }

    /// Builds the remote command that creates an empty file, failing if it
    /// already exists. `set -C` (noclobber) makes `>` refuse to overwrite an
    /// existing path; `:` is the shell no-op builtin, so `: > path` truncates/
    /// creates without invoking an external process.
    static func touchNoclobberCommand(path: String) -> String {
        "set -C; : > \(Self.shellEscape(path))"
    }

    /// Parses the recursive `ls -ld` output produced by `bulkListCommand`.
    /// Names arrive as paths relative to `root` (`./a/b.txt`); each entry is
    /// reassembled into an absolute path and grouped under its parent directory.
    /// Each group is sorted directories-first, then case-insensitive by name —
    /// matching `RemoteFileBrowserDataSource.listDirectory`'s ordering.
    static func parseRecursiveListing(
        output: String,
        root: String,
        symlinkDirPaths: Set<String> = [],
        symlinkResolutions: [String: SymlinkTargetResolution] = [:]
    ) -> [String: [SFTPRichEntry]] {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        var grouped: [String: [SFTPRichEntry]] = [:]
        // Hoisted out of the per-line loop: `DateFormatter` init + locale setup
        // is expensive, and the bulk listing parses one line per remote entry.
        // Allocating a formatter per line turned large remote trees into a
        // multi-second parse stall. Reused across lines; only the BSD branch
        // touches it, and parsing is serialized on the SFTPService actor.
        let bsdFormatter = Self.makeBSDDateFormatter()

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
                mtime = bsdFormatter.date(from: stamp)
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

            let resolution = symlinkResolutions[absolutePath]
                ?? (symlinkDirPaths.contains(absolutePath)
                    ? .directory(canonicalIdentity: absolutePath)
                    : .unresolved(reason: nil))
            grouped[parent, default: []].append(
                SFTPRichEntry(name: name, path: absolutePath, kind: kind,
                              sizeBytes: size, modifiedAt: mtime,
                              symlinkTargetResolution: resolution)
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

        try Task.checkCancellation()
        let symlinkPaths = entries.compactMap { entry -> String? in
            if case .symlink = entry.kind { return entry.path }
            return nil
        }
        let resolutions = await Self.resolveSymlinkMetadata(paths: symlinkPaths) { symlinkPath in
            await Self.resolveCitadelSymlink(sftp: sftp, path: symlinkPath)
        }
        try Task.checkCancellation()

        return entries.map { entry in
            guard let resolution = resolutions[entry.path] else { return entry }
            return SFTPRichEntry(
                name: entry.name,
                path: entry.path,
                kind: entry.kind,
                sizeBytes: entry.sizeBytes,
                modifiedAt: entry.modifiedAt,
                symlinkTargetResolution: resolution
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolveSymlinkMetadata(
        paths: [String],
        maxConcurrent: Int = 4,
        resolver: @escaping @Sendable (String) async -> SymlinkTargetResolution
    ) async -> [String: SymlinkTargetResolution] {
        guard !paths.isEmpty, maxConcurrent > 0 else { return [:] }
        var iterator = paths.makeIterator()

        return await withTaskGroup(of: (String, SymlinkTargetResolution)?.self) { group in
            for _ in 0..<min(maxConcurrent, paths.count) {
                guard let path = iterator.next() else { break }
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return (path, await resolver(path))
                }
            }

            var results: [String: SymlinkTargetResolution] = [:]
            while let result = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let result { results[result.0] = result.1 }
                if let path = iterator.next() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return (path, await resolver(path))
                    }
                }
            }
            return results
        }
    }

    private static func resolveCitadelSymlink(
        sftp: SFTPClient,
        path: String
    ) async -> SymlinkTargetResolution {
        do {
            let canonical = try await sftp.getRealPath(atPath: path)
            let attrs = try await sftp.getAttributes(at: canonical)
            return Self.resolutionForCitadelAttributes(
                canonicalIdentity: canonical,
                permissions: attrs.permissions
            )
        } catch SFTPError.errorStatus(let status) {
            return Self.resolutionForCitadelStatusCode(status.errorCode)
        } catch {
            if error is CancellationError { return .unresolved(reason: nil) }
            return .unresolved(reason: error.localizedDescription)
        }
    }

    static func resolutionForCitadelAttributes(
        canonicalIdentity: String,
        permissions: UInt32?
    ) -> SymlinkTargetResolution {
        guard let permissions else { return .unresolved(reason: nil) }
        return (permissions & Self.S_IFMT) == Self.S_IFDIR
            ? .directory(canonicalIdentity: canonicalIdentity)
            : .file
    }

    static func resolutionForCitadelStatusCode(
        _ statusCode: SFTPStatusCode
    ) -> SymlinkTargetResolution {
        switch statusCode {
        case .noSuchFile:
            return .broken
        case .permissionDenied:
            return .inaccessible
        default:
            return .unresolved(reason: nil)
        }
    }

    // MARK: - SSH stat

    private func statViaSSH(
        target: SSHTarget,
        path: String,
        followSymbolicLinks: Bool = false
    ) async throws -> SFTPRichStat {
        // Try GNU stat first (Linux), fall back to BSD `stat -f` (macOS/FreeBSD).
        // NOTE: separator is the literal string "|" to keep parsing simple even if filenames
        // contain tabs.
        let cmd = Self.transferStatCommand(
            path: path,
            followSymbolicLinks: followSymbolicLinks
        )

        let result = try await runSSH(target: target, command: cmd)
        guard result.exitCode == 0 else {
            throw Self.transferStatFailure(exitCode: result.exitCode, path: path)
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
        let cmd = "cat -- \(Self.shellEscape(path)) | base64"
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
        let cmd = "head -c \(maxBytes) -- \(Self.shellEscape(path)) | base64"
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
        let cmd = "base64 -d > \(Self.shellEscape(path))"
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
