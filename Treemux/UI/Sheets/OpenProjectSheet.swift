//
//  OpenProjectSheet.swift
//  Treemux
//

import SwiftUI

/// Two-mode dialog for opening a project: local folder or remote SSH server.
struct OpenProjectSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    enum ProjectMode: String, CaseIterable {
        case local
        case remote
    }

    @State private var mode: ProjectMode = .local

    // Local mode state
    @State private var localPath: URL?

    // Remote mode state
    @State private var sshTargets: [SSHTarget] = []
    @State private var selectedTargetIndex: Int = 0
    @State private var remotePath: String = ""
    @State private var isLoadingTargets = false
    @State private var showRemoteBrowser = false

    var body: some View {
        VStack(spacing: 16) {
            // Title
            Text(String(localized: "Open Project"))
                .font(.headline)

            // Mode picker
            Picker("", selection: $mode) {
                Text(String(localized: "Local Project")).tag(ProjectMode.local)
                Text(String(localized: "Remote Server")).tag(ProjectMode.remote)
            }
            .pickerStyle(.segmented)

            if mode == .local {
                localModeView
            } else {
                remoteModeView
            }

            // Action buttons
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Open")) {
                    openProject()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canOpen)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            await loadSSHTargets()
        }
    }

    // MARK: - Local Mode

    private var localModeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Choose a local folder:"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(localPath?.path ?? String(localized: "No folder selected"))
                    .foregroundStyle(localPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(String(localized: "Choose…")) {
                    chooseLocalFolder()
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Remote Mode

    private var remoteModeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoadingTargets {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if sshTargets.isEmpty {
                Text(String(localized: "No SSH hosts found in ~/.ssh/config"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                Text(String(localized: "Server:"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedTargetIndex) {
                    ForEach(sshTargets.indices, id: \.self) { index in
                        let target = sshTargets[index]
                        Text(targetLabel(target))
                            .tag(index)
                    }
                }
                .labelsHidden()

                Text(String(localized: "Remote Path:"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("/home/user/project", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "Choose…")) {
                        showRemoteBrowser = true
                    }
                    .disabled(sshTargets.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showRemoteBrowser) {
            if selectedTargetIndex < sshTargets.count {
                RemoteDirectoryBrowser(
                    sshTarget: sshTargets[selectedTargetIndex]
                ) { selectedPath in
                    remotePath = selectedPath
                }
            }
        }
    }

    // MARK: - Actions

    private var canOpen: Bool {
        switch mode {
        case .local:
            return localPath != nil
        case .remote:
            return !sshTargets.isEmpty && !remotePath.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            localPath = panel.url
        }
    }

    private func openProject() {
        switch mode {
        case .local:
            if let path = localPath {
                store.addWorkspaceFromPath(path)
            }
        case .remote:
            guard selectedTargetIndex < sshTargets.count else { return }
            let target = sshTargets[selectedTargetIndex]
            let trimmedPath = remotePath.trimmingCharacters(in: .whitespaces)
            let updatedTarget = SSHTarget(
                host: target.host,
                port: target.port,
                user: target.user,
                identityFile: target.identityFile,
                displayName: target.displayName,
                remotePath: trimmedPath.isEmpty ? nil : trimmedPath
            )
            store.addRemoteWorkspace(target: updatedTarget, name: target.displayName)
        }
    }

    private func loadSSHTargets() async {
        isLoadingTargets = true
        let service = SSHConfigService(configPaths: store.settings.ssh.configPaths)
        sshTargets = await service.loadSSHConfig()
        isLoadingTargets = false
    }

    private func targetLabel(_ target: SSHTarget) -> String {
        if let user = target.user {
            return "\(target.displayName) (\(user)@\(target.host))"
        }
        return "\(target.displayName) (\(target.host))"
    }
}
