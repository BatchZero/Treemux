//
//  SSHConfigService.swift
//  Treemux
//

import Foundation

/// Actor that manages SSH configuration loading, watching for changes,
/// and connection testing.
actor SSHConfigService {

    /// Currently loaded SSH targets from config files.
    private(set) var targets: [SSHTarget] = []

    /// Config file paths to scan.
    private let configPaths: [String]

    init(configPaths: [String] = ["~/.ssh/config"]) {
        self.configPaths = configPaths
    }

    /// Load SSH targets from all configured config files.
    func loadSSHConfig() -> [SSHTarget] {
        var allTargets: [SSHTarget] = []
        for path in configPaths {
            let parsed = SSHConfigParser.parse(configPath: path)
            allTargets.append(contentsOf: parsed)
        }
        targets = allTargets
        return allTargets
    }

    // MARK: - Managed entries (editing)

    /// Load all host blocks across config files, tagged with source path.
    /// First occurrence of an alias wins (mirrors load ordering).
    func loadManagedEntries() -> [ManagedSSHEntry] {
        var result: [ManagedSSHEntry] = []
        var seen = Set<String>()
        for path in configPaths {
            let expanded = (path as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else { continue }
            for entry in SSHConfigDocument(contents: contents).allEntries() {
                let alias = entry.draft.alias
                guard !seen.contains(alias) else { continue }
                seen.insert(alias)
                result.append(ManagedSSHEntry(
                    id: "\(expanded)::\(alias)",
                    draft: entry.draft,
                    sourcePath: expanded,
                    isEditable: entry.isEditable
                ))
            }
        }
        return result
    }

    /// Add a new server to the primary config file.
    func add(_ draft: SSHServerDraft) throws {
        let primary = ((configPaths.first ?? "~/.ssh/config") as NSString).expandingTildeInPath
        try mutate(path: primary) { $0.add(draft) }
    }

    /// Update an existing server in its source file.
    func update(_ draft: SSHServerDraft, originalAlias: String, atSourcePath sourcePath: String) throws {
        try mutate(path: (sourcePath as NSString).expandingTildeInPath) {
            $0.update(alias: originalAlias, to: draft)
        }
    }

    /// Remove a server from its source file.
    func remove(alias: String, atSourcePath sourcePath: String) throws {
        try mutate(path: (sourcePath as NSString).expandingTildeInPath) {
            $0.remove(alias: alias)
        }
    }

    // MARK: - File IO

    private func mutate(path: String, _ transform: (inout SSHConfigDocument) -> Void) throws {
        let fm = FileManager.default
        let existing: String
        if fm.fileExists(atPath: path) {
            existing = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            existing = ""
        }
        var doc = SSHConfigDocument(contents: existing)
        transform(&doc)
        try writeAtomically(doc.render(), to: path)
    }

    private func writeAtomically(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        // Preserve an existing file's permissions; default new files to 0600.
        let perms = ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600

        var data = Data(text.utf8)
        if text.last != "\n" { data.append(0x0A) }  // ensure trailing newline

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        // Create the temp at 0600 first so its contents are never briefly
        // world-readable, then write in place (no .atomic — it would recreate
        // the file under the umask and reopen the window).
        fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        var tmpNeedsCleanup = true
        defer { if tmpNeedsCleanup { try? fm.removeItem(at: tmp) } }

        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        tmpNeedsCleanup = false  // rename consumed the temp file
    }

    /// Test whether an SSH connection can be established to the target.
    func testConnection(_ target: SSHTarget) async -> SSHConnectionStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let user = target.user {
            args.append(contentsOf: ["-l", user])
        }
        args.append(contentsOf: ["-p", String(target.port)])
        args.append(target.host)
        args.append("echo ok")

        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .connected
            } else {
                return .authRequired
            }
        } catch {
            return .unreachable(error)
        }
    }
}

/// Status of an SSH connection test.
enum SSHConnectionStatus {
    case connected
    case authRequired
    case unreachable(Error)
}
