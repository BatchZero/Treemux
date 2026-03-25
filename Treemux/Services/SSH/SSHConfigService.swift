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
