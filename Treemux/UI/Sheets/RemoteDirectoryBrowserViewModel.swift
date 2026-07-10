//
//  RemoteDirectoryBrowserViewModel.swift
//  Treemux
//

import Foundation
import Observation
import SwiftUI

/// Tree node representing a remote directory for the browser UI.
@MainActor
@Observable
class DirectoryNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var children: [DirectoryNode]?  // nil = not yet loaded
    var isExpanded: Bool = false
    var isLoading: Bool = false
    var error: String?

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// ViewModel driving the RemoteDirectoryBrowser sheet.
@MainActor
@Observable
class RemoteDirectoryBrowserViewModel {
    var pathBarText: String = ""
    var rootNodes: [DirectoryNode] = []
    var selectedPath: String? = nil
    var isConnecting: Bool = false
    var connectionError: String? = nil
    var needsPassword: Bool = false
    var password: String = ""

    private let sftpService = SFTPService()
    private let sshTarget: SSHTarget

    init(sshTarget: SSHTarget) {
        self.sshTarget = sshTarget
    }

    /// Connect to the remote server and load the home directory.
    /// Tries key-based auth first; on failure shows password prompt.
    func connect() async {
        isConnecting = true
        connectionError = nil
        needsPassword = false
        do {
            try await sftpService.connect(target: sshTarget)
            try await loadHomeDirectory()
        } catch SFTPServiceError.authenticationFailed {
            // Key auth failed — prompt the user for a password
            needsPassword = true
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    /// Retry connection using the password entered by the user.
    func connectWithPassword() async {
        isConnecting = true
        connectionError = nil
        do {
            try await sftpService.connectWithPassword(target: sshTarget, password: password)
            needsPassword = false
            try await loadHomeDirectory()
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    private func loadHomeDirectory() async throws {
        let home = try await sftpService.homeDirectory()
        pathBarText = home
        let entries = try await sftpService.listDirectories(at: home)
        rootNodes = entries.map { DirectoryNode(name: $0.name, path: $0.path) }
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
        node.isExpanded = true
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
