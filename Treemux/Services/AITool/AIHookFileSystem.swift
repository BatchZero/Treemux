//
//  AIHookFileSystem.swift
//  Treemux
//

import Foundation

/// Filesystem operations needed by hook providers, abstracted so remote (SSH)
/// targets can plug in their own implementation. All methods throw on transport
/// failure; callers should wrap caught errors as `HookInstallError.ioError`.
protocol AIHookFileSystem {
    func exists(_ path: String) async throws -> Bool
    func readText(_ path: String) async throws -> String?     // nil if not present
    func writeText(_ path: String, _ contents: String) async throws
    func removeFile(_ path: String) async throws
    func makeDirectory(_ path: String) async throws
    func makeExecutable(_ path: String) async throws
    /// Expand a path beginning with `~/`. May be a no-op for remote backends
    /// that defer expansion to the remote shell.
    func expand(_ path: String) async throws -> String
}

/// Local filesystem implementation operating on the current user's home.
final class LocalHookFileSystem: AIHookFileSystem {
    private let fm = FileManager.default
    private var home: String { NSHomeDirectory() }

    func expand(_ path: String) async throws -> String {
        if path.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return path
    }

    func exists(_ path: String) async throws -> Bool {
        fm.fileExists(atPath: try await expand(path))
    }

    func readText(_ path: String) async throws -> String? {
        let p = try await expand(path)
        guard fm.fileExists(atPath: p) else { return nil }
        do {
            return try String(contentsOfFile: p, encoding: .utf8)
        } catch {
            throw HookInstallError.ioError("read \(p): \(error.localizedDescription)")
        }
    }

    func writeText(_ path: String, _ contents: String) async throws {
        let p = try await expand(path)
        let dir = (p as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try contents.write(toFile: p, atomically: true, encoding: .utf8)
        } catch {
            throw HookInstallError.ioError("write \(p): \(error.localizedDescription)")
        }
    }

    func removeFile(_ path: String) async throws {
        let p = try await expand(path)
        if fm.fileExists(atPath: p) {
            do {
                try fm.removeItem(atPath: p)
            } catch {
                throw HookInstallError.ioError("remove \(p): \(error.localizedDescription)")
            }
        }
    }

    func makeDirectory(_ path: String) async throws {
        let p = try await expand(path)
        do {
            try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        } catch {
            throw HookInstallError.ioError("mkdir \(p): \(error.localizedDescription)")
        }
    }

    func makeExecutable(_ path: String) async throws {
        let p = try await expand(path)
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        } catch {
            throw HookInstallError.ioError("chmod \(p): \(error.localizedDescription)")
        }
    }
}
