//
//  SSHMultiplexing.swift
//  Treemux
//

import Foundation

/// Builds the OpenSSH argument vector shared by every system-ssh invocation
/// (SFTPService file operations and GitRepositoryService remote inspection).
///
/// Connection multiplexing: the first connection to a host becomes the
/// ControlMaster; subsequent commands within `controlPersistSeconds` reuse its
/// TCP + auth session, eliminating the full handshake per command. Degradation
/// is silent by design: if the socket directory cannot be created the mux
/// options are simply omitted, and `ControlMaster=auto` itself falls back to a
/// plain connection when the socket is unusable or the server forbids
/// multiplexing — behavior then matches pre-P2 (one connection per command).
enum SSHMultiplexing {
    /// How long (seconds) the master connection lingers after its last client.
    static let controlPersistSeconds = 60

    /// Paths whose ssh-mux directory has already been created successfully.
    ///
    /// WHY this cache exists (do not "simplify" it away): `controlOptions` is
    /// called on the hot path of every ssh argument construction, including
    /// concurrent remote-workspace refreshes. If it called `createDirectory`
    /// unconditionally on every call, it would race with any code that
    /// deletes the state directory concurrently (e.g. test teardown removing
    /// `~/.treemux-debug`). `FileManager.createDirectory` racing
    /// `FileManager.removeItem` on the same path deterministically yields
    /// NSCocoaErrorDomain Code=513 (EPERM) on macOS — reproduced in isolation
    /// with a 4-writer/1-remover loop failing within ~100 iterations, and
    /// observed in practice as `WorkspaceStoreIconCacheTests` flaking in every
    /// full-suite run. Ensuring the directory only once per path makes
    /// arg-building read-only (no filesystem writes) after the first success.
    ///
    /// Accepted trade-off: if the directory is deleted mid-process after
    /// being cached, later calls still emit ControlPath options pointing at a
    /// now-missing directory. This is safe because OpenSSH's
    /// `ControlMaster=auto` silently disables multiplexing when the socket
    /// path is unusable, falling back to a plain connection — matching this
    /// module's documented silent-degradation contract.
    private static var ensuredDirectories = Set<String>()
    private static let ensureLock = NSLock()

    static func controlDirectoryURL(
        stateDirectory: URL = treemuxStateDirectoryURL()
    ) -> URL {
        stateDirectory.appendingPathComponent("ssh-mux", isDirectory: true)
    }

    /// ControlMaster/ControlPath/ControlPersist options. The socket directory
    /// (owner-only, 0700) is created on demand but only once per state-directory
    /// path — see `ensuredDirectories` above for why repeated per-call mkdirs
    /// are unsafe. Empty when the directory cannot be created (and, in that
    /// case, NOT cached, so a later call may retry once the obstruction is
    /// gone). `%C` hashes host+port+user so distinct targets never share a
    /// socket, and its fixed length keeps the path under the unix-socket path
    /// limit.
    static func controlOptions(
        stateDirectory: URL = treemuxStateDirectoryURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        let dir = controlDirectoryURL(stateDirectory: stateDirectory)

        ensureLock.lock()
        let alreadyEnsured = ensuredDirectories.contains(dir.path)
        ensureLock.unlock()

        if !alreadyEnsured {
            do {
                // Create the state directory itself with no explicit attributes,
                // matching how the rest of the app creates it (see
                // treemuxStateDirectoryURL / ~/.treemux-debug usage elsewhere).
                // Passing 0700 attributes here with withIntermediateDirectories
                // would narrow the state directory itself to owner-only when it
                // doesn't pre-exist, which is not this module's call to make.
                try fileManager.createDirectory(
                    at: stateDirectory,
                    withIntermediateDirectories: true
                )
                // The ssh-mux subdirectory holds the actual control sockets, so
                // it is the one that gets owner-only (0700) permissions.
                try fileManager.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return []
            }
            ensureLock.lock()
            ensuredDirectories.insert(dir.path)
            ensureLock.unlock()
        }

        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(dir.path)/%C",
            "-o", "ControlPersist=\(controlPersistSeconds)s"
        ]
    }

    /// Full `/usr/bin/ssh` argument list: base options + multiplexing +
    /// port/identity/target/command. Single source of truth for both services.
    static func sshArguments(
        target: SSHTarget,
        command: String,
        stateDirectory: URL = treemuxStateDirectoryURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        args += controlOptions(stateDirectory: stateDirectory, fileManager: fileManager)
        args += ["-p", "\(target.port)"]
        if let identityFile = target.identityFile {
            args += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        args.append("\(target.user ?? NSUserName())@\(target.host)")
        args.append(command)
        return args
    }
}
