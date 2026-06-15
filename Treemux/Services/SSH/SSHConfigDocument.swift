//
//  SSHConfigDocument.swift
//  Treemux
//

import Foundation

/// A fidelity-preserving, line-based model of an OpenSSH config file.
/// Parsing keeps every line verbatim; mutations only touch the relevant block,
/// leaving comments, wildcard hosts, and unknown directives untouched.
struct SSHConfigDocument {

    /// One entry surfaced to the UI (without source-file info).
    struct Entry: Equatable {
        let draft: SSHServerDraft
        let isEditable: Bool
    }

    /// Internal description of a `Host` block's line range.
    private struct HostBlock {
        let tokens: [String]   // tokens after the `Host` keyword
        let start: Int         // index of the `Host` line
        let end: Int           // exclusive
        var alias: String { tokens.first ?? "" }
        var isEditable: Bool {
            tokens.count == 1 && !tokens[0].contains("*") && !tokens[0].contains("?")
        }
    }

    private(set) var lines: [String]

    init(contents: String) {
        lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
    }

    /// Reconstruct the full file text verbatim. Note: after `add()`/`remove()`
    /// the result may not end in a trailing newline; the file writer is
    /// responsible for ensuring one.
    func render() -> String {
        lines.joined(separator: "\n")
    }

    /// All host blocks, in file order, classified by editability.
    func allEntries() -> [Entry] {
        hostBlocks().map { block in
            Entry(draft: draft(for: block, editable: block.isEditable),
                  isEditable: block.isEditable)
        }
    }

    // MARK: - Parsing helpers

    /// Parse a line into (lowercased keyword, value). Returns nil for blanks/comments.
    static func directive(of line: String) -> (keyword: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        // ssh_config(5): keyword and value may be separated by whitespace and/or
        // a single '='.
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        if let range = trimmed.rangeOfCharacter(from: separators) {
            let keyword = String(trimmed[..<range.lowerBound]).lowercased()
            let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: separators)
            return (keyword, value)
        }
        return (trimmed.lowercased(), "")
    }

    private func hostBlocks() -> [HostBlock] {
        var blocks: [HostBlock] = []
        var start: Int?
        var tokens: [String] = []
        for (i, line) in lines.enumerated() {
            if let d = Self.directive(of: line), d.keyword == "host" {
                if let s = start {
                    blocks.append(HostBlock(tokens: tokens, start: s, end: i))
                }
                start = i
                tokens = d.value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            }
        }
        if let s = start {
            blocks.append(HostBlock(tokens: tokens, start: s, end: lines.count))
        }
        return blocks
    }

    // MARK: - Mutations

    /// Append a well-formatted block at the end of the file.
    mutating func add(_ draft: SSHServerDraft) {
        // Trim trailing blank lines, then add exactly one separator if non-empty.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var block: [String] = []
        if !lines.isEmpty { block.append("") }
        block.append("Host \(draft.alias)")
        block.append("    HostName \(draft.hostName)")
        if draft.port != 22 { block.append("    Port \(draft.port)") }
        if !draft.user.isEmpty { block.append("    User \(draft.user)") }
        if !draft.identityFile.isEmpty { block.append("    IdentityFile \(draft.identityFile)") }
        lines.append(contentsOf: block)
    }

    /// Remove a managed block entirely, then collapse blank-line runs.
    mutating func remove(alias: String) {
        guard let block = hostBlocks().first(where: { $0.isEditable && $0.alias == alias })
        else { return }
        lines.removeSubrange(block.start..<block.end)
        normalizeBlankRuns()
    }

    /// Collapse consecutive blank lines to one and drop leading/trailing blanks.
    private mutating func normalizeBlankRuns() {
        var result: [String] = []
        var prevBlank = false
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank && prevBlank { continue }
            result.append(line)
            prevBlank = blank
        }
        while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeFirst()
        }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        lines = result
    }

    /// Surgically update a managed block's known directives in place.
    mutating func update(alias: String, to draft: SSHServerDraft) {
        // HostName is mandatory; refuse to corrupt the block by clearing it.
        guard !draft.hostName.isEmpty,
              hostBlocks().contains(where: { $0.isEditable && $0.alias == alias }) else { return }
        setDirective(blockAlias: alias, keyword: "HostName",
                     value: draft.hostName.isEmpty ? nil : draft.hostName)
        setDirective(blockAlias: alias, keyword: "Port",
                     value: draft.port == 22 ? nil : String(draft.port))
        setDirective(blockAlias: alias, keyword: "User",
                     value: draft.user.isEmpty ? nil : draft.user)
        setDirective(blockAlias: alias, keyword: "IdentityFile",
                     value: draft.identityFile.isEmpty ? nil : draft.identityFile)
        // Rename last so the lookups above still resolve by the original alias.
        if draft.alias != alias,
           let block = hostBlocks().first(where: { $0.isEditable && $0.alias == alias }) {
            lines[block.start] = replaceHostToken(lines[block.start], with: draft.alias)
        }
    }

    /// Set / insert / remove a single known directive within a block.
    /// `value == nil` removes the line if present; otherwise replaces or appends.
    private mutating func setDirective(blockAlias: String, keyword: String, value: String?) {
        guard let block = hostBlocks().first(where: { $0.isEditable && $0.alias == blockAlias })
        else { return }

        var existing: Int?
        for i in block.start..<block.end {
            if let d = Self.directive(of: lines[i]), d.keyword == keyword.lowercased() {
                existing = i
                break
            }
        }

        if let value {
            let newLine = "\(blockIndent(block))\(keyword) \(value)"
            if let idx = existing {
                lines[idx] = newLine
            } else {
                // Append after the last non-blank line of the block.
                var insertAt = block.start + 1
                for i in (block.start + 1)..<block.end
                where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    insertAt = i + 1
                }
                lines.insert(newLine, at: insertAt)
            }
        } else if let idx = existing {
            lines.remove(at: idx)
        }
    }

    /// Indentation used by directive lines in the block (default 4 spaces).
    private func blockIndent(_ block: HostBlock) -> String {
        for i in (block.start + 1)..<block.end where Self.directive(of: lines[i]) != nil {
            let ws = lines[i].prefix { $0 == " " || $0 == "\t" }
            return ws.isEmpty ? "    " : String(ws)
        }
        return "    "
    }

    /// Replace the single host token on a `Host` line, preserving leading
    /// whitespace and the original keyword text.
    private func replaceHostToken(_ line: String, with newAlias: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(leading.count)
        if let range = rest.rangeOfCharacter(from: .whitespaces) {
            let keyword = rest[..<range.lowerBound]
            return "\(leading)\(keyword) \(newAlias)"
        }
        return "\(leading)Host \(newAlias)"
    }

    private func draft(for block: HostBlock, editable: Bool) -> SSHServerDraft {
        let aliasForDisplay = editable ? block.alias : block.tokens.joined(separator: " ")
        var d = SSHServerDraft(alias: aliasForDisplay, hostName: "")
        for i in block.start..<block.end {
            guard let dir = Self.directive(of: lines[i]) else { continue }
            switch dir.keyword {
            case "hostname": d.hostName = dir.value
            case "port": d.port = Int(dir.value) ?? 22
            case "user": d.user = dir.value
            case "identityfile": d.identityFile = dir.value
            default: break
            }
        }
        return d
    }
}

/// Standalone atomic writer for SSH config text, reused by `SSHConfigService`
/// and the raw editor. Creates the temp at 0600 first (never world-readable),
/// preserves an existing file's permissions, and cleans up the temp on failure.
enum SSHConfigRawWriter {
    static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }

        let perms = ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600

        var data = Data(text.utf8)
        if text.last != "\n" { data.append(0x0A) }

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
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
        tmpNeedsCleanup = false
    }
}
