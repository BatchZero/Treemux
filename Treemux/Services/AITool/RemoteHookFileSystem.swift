//
//  RemoteHookFileSystem.swift
//  Treemux
//

import Foundation

/// Remote `AIHookFileSystem` that runs operations over SSH by shelling out to
/// `/usr/bin/ssh`. Uses `BatchMode=yes` so authentication failures fail fast
/// rather than hanging on a password prompt, and base64-encodes file contents
/// during writes to avoid shell quoting hazards.
final class RemoteHookFileSystem: AIHookFileSystem {

    let target: SSHTarget

    init(target: SSHTarget) {
        self.target = target
    }

    // MARK: - Path expansion

    /// Don't resolve `~/` on the client side — let the remote shell expand it
    /// in the context of the target user's home directory.
    func expand(_ path: String) async throws -> String {
        path
    }

    // MARK: - File operations

    func exists(_ path: String) async throws -> Bool {
        let res = try await runSSH("test -e \(shellQuote(path))")
        return res.exitCode == 0
    }

    func readText(_ path: String) async throws -> String? {
        let res = try await runSSH("cat \(shellQuote(path)) 2>/dev/null")
        return res.exitCode == 0 ? res.output : nil
    }

    func writeText(_ path: String, _ contents: String) async throws {
        let dir = (path as NSString).deletingLastPathComponent
        let mkdir = try await runSSH("mkdir -p \(shellQuote(dir))")
        if mkdir.exitCode != 0 {
            throw HookInstallError.ioError("mkdir \(dir) failed: \(mkdir.errorOutput)")
        }
        // Base64-encode the payload so arbitrary content (newlines, quotes,
        // backslashes, etc.) survives transport through the remote shell.
        let encoded = Data(contents.utf8).base64EncodedString()
        let cmd = "printf '%s' \(shellQuote(encoded)) | base64 -d > \(shellQuote(path))"
        let res = try await runSSH(cmd)
        if res.exitCode != 0 {
            throw HookInstallError.ioError("write \(path) failed: \(res.errorOutput)")
        }
    }

    func removeFile(_ path: String) async throws {
        let res = try await runSSH("rm -f \(shellQuote(path))")
        if res.exitCode != 0 {
            throw HookInstallError.ioError("rm \(path) failed: \(res.errorOutput)")
        }
    }

    func makeDirectory(_ path: String) async throws {
        let res = try await runSSH("mkdir -p \(shellQuote(path))")
        if res.exitCode != 0 {
            throw HookInstallError.ioError("mkdir \(path) failed: \(res.errorOutput)")
        }
    }

    func makeExecutable(_ path: String) async throws {
        let res = try await runSSH("chmod +x \(shellQuote(path))")
        if res.exitCode != 0 {
            throw HookInstallError.ioError("chmod +x \(path) failed: \(res.errorOutput)")
        }
    }

    // MARK: - SSH plumbing

    /// Build the argv passed to `/usr/bin/ssh` for a given remote command.
    /// Default port (22) is omitted from argv to keep argv short and match
    /// what users would type interactively.
    func sshArgs(for command: String) -> [String] {
        var args: [String] = []
        if let port = nonDefaultPort {
            args += ["-p", "\(port)"]
        }
        if let id = target.identityFile {
            args += ["-i", id]
        }
        args += ["-o", "BatchMode=yes"]
        args += ["-o", "ConnectTimeout=10"]
        args += [hostSpec]
        args += ["--", command]
        return args
    }

    private var hostSpec: String {
        if let user = target.user, !user.isEmpty {
            return "\(user)@\(target.host)"
        }
        return target.host
    }

    private var nonDefaultPort: Int? {
        target.port == 22 ? nil : target.port
    }

    private func runSSH(_ remoteCommand: String) async throws -> CommandResult {
        let args = sshArgs(for: remoteCommand)
        do {
            return try await ShellCommandRunner.run("/usr/bin/ssh", arguments: args)
        } catch {
            throw HookInstallError.ioError("ssh \(target.host) failed: \(error.localizedDescription)")
        }
    }

    /// POSIX single-quote a string so the remote shell receives it verbatim.
    /// Embedded single quotes are escaped with the standard `'\''` sequence.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

#if DEBUG
/// Test-only hooks for exercising private helpers without exposing them in
/// release builds.
enum RemoteHookFileSystemTesting {
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func sshArgs(for command: String, target: SSHTarget) -> [String] {
        let fs = RemoteHookFileSystem(target: target)
        return fs.sshArgs(for: command)
    }
}
#endif
