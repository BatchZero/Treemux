//
//  SSHConfigParser.swift
//  Treemux
//

import Foundation

/// Parses OpenSSH config files into SSHTarget models.
enum SSHConfigParser {

    /// Parse an SSH config file at the given path into a list of SSHTarget.
    static func parse(configPath: String) -> [SSHTarget] {
        let expandedPath = (configPath as NSString).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            return []
        }
        return parse(contents: contents)
    }

    /// Parse SSH config text content into SSHTarget entries.
    static func parse(contents: String) -> [SSHTarget] {
        var targets: [SSHTarget] = []
        var currentHost: String?
        var hostName: String?
        var port: Int = 22
        var user: String?
        var identityFile: String?

        func flushCurrent() {
            guard let host = currentHost else { return }
            // Skip wildcard and pattern hosts
            guard !host.contains("*") && !host.contains("?") else {
                resetFields()
                return
            }
            let resolvedHostName = hostName ?? host
            targets.append(SSHTarget(
                host: resolvedHostName,
                port: port,
                user: user,
                identityFile: identityFile,
                displayName: host,
                remotePath: nil
            ))
            resetFields()
        }

        func resetFields() {
            currentHost = nil
            hostName = nil
            port = 22
            user = nil
            identityFile = nil
        }

        let lines = contents.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split into keyword and value
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let keyword = String(parts[0]).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            switch keyword {
            case "host":
                flushCurrent()
                currentHost = value
            case "hostname":
                hostName = value
            case "port":
                port = Int(value) ?? 22
            case "user":
                user = value
            case "identityfile":
                identityFile = value
            default:
                break
            }
        }

        // Flush last entry
        flushCurrent()

        return targets
    }
}
