//
//  AIToolService.swift
//  Treemux
//

import Foundation

/// Manages AI tool detection, preset configurations, and launch helpers.
@MainActor
final class AIToolService: ObservableObject {

    /// Available AI agent presets loaded from ~/.treemux/agents/.
    @Published var presets: [AgentSessionConfig] = []

    private let agentsDirectory: URL

    init() {
        self.agentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".treemux/agents", isDirectory: true)
        loadPresets()
    }

    // MARK: - Detection

    /// Detect if an AI tool is running based on a process name.
    func detect(processName: String) -> AIToolDetection? {
        guard let kind = AIToolKind.detect(processName: processName) else {
            return nil
        }
        return AIToolDetection(
            kind: kind,
            isRunning: true,
            processName: processName
        )
    }

    // MARK: - Presets

    /// Load agent presets from the agents directory and built-in defaults.
    func loadPresets() {
        var configs: [AgentSessionConfig] = builtInPresets()

        let fm = FileManager.default
        try? fm.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)

        if let files = try? fm.contentsOfDirectory(at: agentsDirectory, includingPropertiesForKeys: nil) {
            let decoder = JSONDecoder()
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let config = try? decoder.decode(AgentSessionConfig.self, from: data) {
                    // Replace built-in if same name, or append
                    if let idx = configs.firstIndex(where: { $0.name == config.name }) {
                        configs[idx] = config
                    } else {
                        configs.append(config)
                    }
                }
            }
        }

        presets = configs
    }

    /// Generate a launch configuration for an agent preset.
    func launchConfig(for preset: AgentSessionConfig, workingDirectory: URL) -> SessionBackendConfiguration {
        .agent(preset)
    }

    // MARK: - Built-in Presets

    private func builtInPresets() -> [AgentSessionConfig] {
        [
            AgentSessionConfig(
                name: "Claude Code",
                launchCommand: "claude",
                arguments: [],
                environment: [:],
                toolKind: .claudeCode
            ),
            AgentSessionConfig(
                name: "Codex",
                launchCommand: "codex",
                arguments: [],
                environment: [:],
                toolKind: .openaiCodex
            ),
        ]
    }

    /// Write built-in preset JSON files if they don't exist.
    func ensureBuiltInPresetsExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for preset in builtInPresets() {
            let filename = preset.name.lowercased().replacingOccurrences(of: " ", with: "-") + ".json"
            let file = agentsDirectory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: file.path) {
                if let data = try? encoder.encode(preset) {
                    try? data.write(to: file)
                }
            }
        }
    }
}
