//
//  WorkspaceStatePersistence.swift
//  Treemux
//

import Foundation

/// Reads and writes `PersistedWorkspaceState` to a JSON file in the state directory.
struct WorkspaceStatePersistence {
    private let fileManager = FileManager.default

    /// Loads workspace state from disk, returning an empty state if the file is missing or corrupt.
    func load() -> PersistedWorkspaceState {
        let url = stateFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [])
        }
        do {
            return try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
        } catch {
            return PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [])
        }
    }

    /// Saves workspace state to disk as pretty-printed JSON.
    func save(_ state: PersistedWorkspaceState) throws {
        let directory = stateDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateFileURL(), options: .atomic)
    }

    private func stateDirectoryURL() -> URL {
        treemuxStateDirectoryURL(fileManager: fileManager)
    }

    private func stateFileURL() -> URL {
        stateDirectoryURL().appendingPathComponent("workspace-state.json")
    }
}
