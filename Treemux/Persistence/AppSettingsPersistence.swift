//
//  AppSettingsPersistence.swift
//  Treemux
//

import Foundation

// MARK: - State Directory Helpers

private let treemuxPersistenceIsDebugBuild: Bool = {
    #if DEBUG
    true
    #else
    false
    #endif
}()

/// Returns the name of the state directory based on the build configuration.
func treemuxStateDirectoryName(isDebugBuild: Bool = treemuxPersistenceIsDebugBuild) -> String {
    isDebugBuild ? ".treemux-debug" : ".treemux"
}

/// Returns the URL for the treemux state directory under the user's home folder.
func treemuxStateDirectoryURL(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        treemuxStateDirectoryName(),
        isDirectory: true
    )
}

// MARK: - AppSettingsPersistence

/// Reads and writes `AppSettings` to a JSON file in the state directory.
struct AppSettingsPersistence {
    private let fileManager = FileManager.default

    /// Loads settings from disk, returning defaults if the file is missing or corrupt.
    func load() -> AppSettings {
        let url = settingsFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    /// Saves settings to disk as pretty-printed JSON.
    func save(_ settings: AppSettings) throws {
        let directory = stateDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL(), options: .atomic)
    }

    private func stateDirectoryURL() -> URL {
        treemuxStateDirectoryURL(fileManager: fileManager)
    }

    private func settingsFileURL() -> URL {
        stateDirectoryURL().appendingPathComponent("settings.json")
    }
}
