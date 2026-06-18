//
//  OpenProjectSheet.swift
//  Treemux
//

import SwiftUI

/// Two-mode dialog for opening a project: local folder or remote SSH server.
struct OpenProjectSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var languageManager: LanguageManager
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
    @State private var managedEntries: [ManagedSSHEntry] = []
    @State private var serverEditMode: SSHServerEditSheet.Mode?

    var body: some View {
        VStack(spacing: 16) {
            // Title
            Text("Open Project")
                .font(.headline)

            // Mode picker
            Picker("", selection: $mode) {
                Text("Local Project").tag(ProjectMode.local)
                Text("Remote Server").tag(ProjectMode.remote)
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
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(UtilityButtonStyle(tint: theme.textSecondary, activeTint: theme.accentColor, border: theme.dividerColor))

                Button("Open") {
                    openProject()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canOpen)
                .buttonStyle(PillButtonStyle(accent: theme.accentColor, onAccent: theme.onAccentColor))
            }
        }
        .padding(Spacing.lg)
        .frame(width: 420)
        .task {
            await loadSSHTargets()
        }
    }

    // MARK: - Local Mode

    private var localModeView: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Choose a local folder:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text(localPath?.path ?? String(localized: "No folder selected"))
                    .foregroundStyle(localPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") {
                    chooseLocalFolder()
                }
                .buttonStyle(UtilityButtonStyle(tint: theme.textSecondary, activeTint: theme.accentColor, border: theme.dividerColor))
            }
            .padding(Spacing.xs)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Remote Mode

    private var remoteModeView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Server section: picker and its management buttons share one row so
            // New/Edit sit next to the thing they operate on.
            VStack(alignment: .leading, spacing: 6) {
                Text("Server:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if isLoadingTargets {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if sshTargets.isEmpty {
                        Text("No SSH hosts found in ~/.ssh/config")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("", selection: $selectedTargetIndex) {
                            ForEach(sshTargets.indices, id: \.self) { index in
                                let target = sshTargets[index]
                                Text(targetLabel(target))
                                    .tag(index)
                            }
                        }
                        .labelsHidden()
                    }

                    Button {
                        serverEditMode = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(LocalizedStringKey("New Server"))

                    Button {
                        if let entry = selectedManagedEntry() {
                            serverEditMode = .edit(entry)
                        }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .help(LocalizedStringKey("Edit Server"))
                    .disabled(selectedManagedEntry()?.isEditable != true)
                }
            }

            // Remote path section.
            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Path:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("/home/user/project", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        showRemoteBrowser = true
                    }
                    .disabled(sshTargets.isEmpty)
                }
            }
            .disabled(sshTargets.isEmpty)
        }
        .sheet(isPresented: $showRemoteBrowser) {
            if selectedTargetIndex < sshTargets.count {
                RemoteDirectoryBrowser(
                    sshTarget: sshTargets[selectedTargetIndex]
                ) { selectedPath in
                    remotePath = selectedPath
                }
                .environment(\.locale, languageManager.locale)
            }
        }
        .sheet(item: $serverEditMode) { editMode in
            SSHServerEditSheet(
                mode: editMode,
                existingAliases: managedEntries.map { $0.draft.alias },
                service: SSHConfigService(configPaths: store.settings.ssh.configPaths)
            ) { savedTarget in
                Task { await loadSSHTargets(selecting: savedTarget.displayName) }
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
            // Use remote path's last component as name (like local workspaces),
            // fall back to SSH host display name when no path is specified.
            let workspaceName: String
            if let remotePath = updatedTarget.remotePath,
               !remotePath.isEmpty {
                workspaceName = (remotePath as NSString).lastPathComponent
            } else {
                workspaceName = target.displayName
            }
            store.addRemoteWorkspace(target: updatedTarget, name: workspaceName)
        }
    }

    private func loadSSHTargets(selecting alias: String? = nil) async {
        isLoadingTargets = true
        let service = SSHConfigService(configPaths: store.settings.ssh.configPaths)
        sshTargets = await service.loadSSHConfig()
        managedEntries = await service.loadManagedEntries()
        if let alias, let idx = sshTargets.firstIndex(where: { $0.displayName == alias }) {
            selectedTargetIndex = idx
        } else if selectedTargetIndex >= sshTargets.count {
            selectedTargetIndex = 0
        }
        isLoadingTargets = false
    }

    /// The managed entry corresponding to the currently selected picker target.
    private func selectedManagedEntry() -> ManagedSSHEntry? {
        guard selectedTargetIndex < sshTargets.count else { return nil }
        let alias = sshTargets[selectedTargetIndex].displayName
        return managedEntries.first { $0.draft.alias == alias }
    }

    private func targetLabel(_ target: SSHTarget) -> String {
        if let user = target.user {
            return "\(target.displayName) (\(user)@\(target.host))"
        }
        return "\(target.displayName) (\(target.host))"
    }
}
