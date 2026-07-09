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

    static func controlDirectoryURL(
        stateDirectory: URL = treemuxStateDirectoryURL()
    ) -> URL {
        stateDirectory.appendingPathComponent("ssh-mux", isDirectory: true)
    }

    /// ControlMaster/ControlPath/ControlPersist options, creating the socket
    /// directory (owner-only, 0700) on demand. Empty when the directory cannot
    /// be created. `%C` hashes host+port+user so distinct targets never share
    /// a socket, and its fixed length keeps the path under the unix-socket
    /// path limit.
    static func controlOptions(
        stateDirectory: URL = treemuxStateDirectoryURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        let dir = controlDirectoryURL(stateDirectory: stateDirectory)
        do {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return []
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
