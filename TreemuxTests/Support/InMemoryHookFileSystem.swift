//
//  InMemoryHookFileSystem.swift
//  TreemuxTests
//

import Foundation
@testable import Treemux

/// In-memory filesystem used by `AIHookProvider` unit tests. Keys are
/// fully-expanded paths (no `~/`).
final class InMemoryHookFileSystem: AIHookFileSystem, @unchecked Sendable {
    private var files: [String: String] = [:]
    private var directories: Set<String> = []
    private var executables: Set<String> = []
    private let home = "/Users/test"

    func expand(_ path: String) async throws -> String {
        if path.hasPrefix("~/") {
            return home + "/" + String(path.dropFirst(2))
        }
        return path
    }

    func exists(_ path: String) async throws -> Bool {
        let p = try await expand(path)
        return files[p] != nil || directories.contains(p)
    }

    func readText(_ path: String) async throws -> String? {
        files[try await expand(path)]
    }

    func writeText(_ path: String, _ contents: String) async throws {
        let p = try await expand(path)
        files[p] = contents
    }

    func removeFile(_ path: String) async throws {
        let p = try await expand(path)
        files.removeValue(forKey: p)
        executables.remove(p)
    }

    func makeDirectory(_ path: String) async throws {
        let p = try await expand(path)
        directories.insert(p)
    }

    func makeExecutable(_ path: String) async throws {
        let p = try await expand(path)
        executables.insert(p)
    }

    /// Test-only: did `makeExecutable` fire on this path?
    func isExecutable(_ path: String) async throws -> Bool {
        executables.contains(try await expand(path))
    }
}
