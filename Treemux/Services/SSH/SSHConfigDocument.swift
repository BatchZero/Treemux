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

    /// Reconstruct the full file text verbatim.
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
        if let range = trimmed.rangeOfCharacter(from: .whitespaces) {
            let keyword = String(trimmed[..<range.lowerBound]).lowercased()
            let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
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
