//
//  RemoteDirectoryBrowserViewModel.swift
//  Treemux
//

import Foundation
import SwiftUI

/// Tree node representing a remote directory for the browser UI.
@MainActor
class DirectoryNode: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let path: String
    @Published var children: [DirectoryNode]?  // nil = not yet loaded
    @Published var isLoading: Bool = false
    @Published var error: String?

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// ViewModel driving the RemoteDirectoryBrowser sheet.
@MainActor
class RemoteDirectoryBrowserViewModel: ObservableObject {
    @Published var pathBarText: String = ""
    @Published var rootNodes: [DirectoryNode] = []
    @Published var selectedPath: String? = nil
    @Published var isConnecting: Bool = false
    @Published var connectionError: String? = nil

    private let sftpService = SFTPService()
    private let sshTarget: SSHTarget

    init(sshTarget: SSHTarget) {
        self.sshTarget = sshTarget
    }

    /// Connect to the remote server and load the home directory.
    func connect() async {
        isConnecting = true
        connectionError = nil
        do {
            try await sftpService.connect(target: sshTarget)
            let home = try await sftpService.homeDirectory()
            pathBarText = home
            let entries = try await sftpService.listDirectories(at: home)
            rootNodes = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    /// Navigate to a specific path (from path bar input).
    func navigateTo(path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isConnecting = true
        connectionError = nil
        do {
            let entries = try await sftpService.listDirectories(at: trimmed)
            pathBarText = trimmed
            selectedPath = nil
            rootNodes = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    /// Lazy-load children for a directory node when expanded.
    func expandNode(_ node: DirectoryNode) async {
        guard node.children == nil else { return }  // Already loaded
        node.isLoading = true
        node.error = nil
        do {
            let entries = try await sftpService.listDirectories(at: node.path)
            node.children = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
        } catch {
            node.error = error.localizedDescription
            node.children = []  // Mark as loaded (empty) to prevent retry loops
        }
        node.isLoading = false
    }

    /// Disconnect from the server.
    func disconnect() async {
        await sftpService.disconnect()
    }
}
