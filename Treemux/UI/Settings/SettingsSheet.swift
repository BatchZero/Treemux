//
//  SettingsSheet.swift
//  Treemux
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar-based settings sheet following macOS System Settings pattern.
struct SettingsSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var languageManager: LanguageManager
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AppSettings()
    @State private var originalSettings = AppSettings()

    private var hasChanges: Bool {
        draft != originalSettings
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, terminal, theme, sidebarIcons, ssh, shortcuts, updates

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .general: return "General"
            case .terminal: return "Terminal"
            case .theme: return "Theme"
            case .sidebarIcons: return "Sidebar Icons"
            case .ssh: return "SSH"
            case .shortcuts: return "Shortcuts"
            case .updates: return "Updates"
            }
        }

        var subtitle: LocalizedStringKey {
            switch self {
            case .general: return "Language and startup behavior"
            case .terminal: return "Shell, font, and cursor settings"
            case .theme: return "Color themes and appearance"
            case .sidebarIcons: return "Customize icons for workspaces and worktrees"
            case .ssh: return "SSH config file paths"
            case .shortcuts: return "Customize keyboard shortcuts"
            case .updates: return "Software update preferences"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .terminal: return "apple.terminal"
            case .theme: return "paintbrush"
            case .sidebarIcons: return "paintpalette"
            case .ssh: return "network"
            case .shortcuts: return "keyboard"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }
    }

    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            // Detail
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.title)
                        .font(.system(size: 20, weight: .semibold))
                    Text(selection.subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                Divider()

                // Content
                ScrollView {
                    settingsContent(for: selection)
                        .padding(4)
                }

                // Footer with Save / Cancel
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") {
                        // Revert theme if it was changed during preview
                        if draft.activeThemeID != originalSettings.activeThemeID {
                            theme.setActiveTheme(originalSettings.activeThemeID)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Save") {
                        store.updateSettings(draft)
                        languageManager.apply(languageCode: draft.language)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 460)
        .task {
            draft = store.settings
            originalSettings = store.settings
        }
    }

    // MARK: - Section Content

    @ViewBuilder
    private func settingsContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView(settings: $draft)
        case .terminal:
            TerminalSettingsView(settings: $draft)
        case .theme:
            ThemeSettingsView(settings: $draft, themeManager: theme)
        case .sidebarIcons:
            SidebarIconsSettingsView(settings: $draft)
        case .ssh:
            SSHSettingsView(settings: $draft)
        case .shortcuts:
            ShortcutsSettingsView(settings: $draft)
        case .updates:
            UpdateSettingsView(settings: $draft)
        }
    }
}

// MARK: - General Settings

private struct GeneralSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Picker("Language", selection: $settings.language) {
                Text("Follow System").tag("system")
                Text("English").tag("en")
                Text("中文").tag("zh-Hans")
            }

            Picker("On Startup", selection: $settings.startup.restoreLastSession) {
                Text("Restore Last Session").tag(true)
                Text("Blank Window").tag(false)
            }

            Section {
                Toggle("Show Default Terminal (~)", isOn: $settings.showDefaultTerminal)
            } footer: {
                Text("Always shown when no other workspace exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable code completion in editor", isOn: $settings.enableCodeCompletion)
            } footer: {
                Text("Suggestions are drawn from words already present in the buffer. LSP-based completion is not yet supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("File Tree Density", selection: $settings.fileTree.density) {
                    ForEach(TreeDensity.allCases) { density in
                        Text(densityTitle(density)).tag(density)
                    }
                }
            } footer: {
                Text("Row height and font size in the file browser tree.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func densityTitle(_ density: TreeDensity) -> LocalizedStringKey {
        switch density {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
}

// MARK: - Terminal Settings

private struct TerminalSettingsView: View {
    @Binding var settings: AppSettings

    private var offsetLabel: String {
        let offset = settings.terminal.fontSizeOffset
        return offset >= 0 ? "+\(offset)" : "\(offset)"
    }

    private var canDecrease: Bool {
        settings.terminal.fontSizeOffset > AdaptiveFontSizeCalculator.offsetRange.lowerBound
    }

    private var canIncrease: Bool {
        settings.terminal.fontSizeOffset < AdaptiveFontSizeCalculator.offsetRange.upperBound
    }

    private var currentDisplayPointSize: Int {
        AdaptiveFontSizeCalculator.fontSize(
            for: NSScreen.main,
            offset: settings.terminal.fontSizeOffset
        )
    }

    var body: some View {
        Form {
            TextField("Default Shell", text: $settings.terminal.defaultShell)

            Section {
                HStack(spacing: 8) {
                    Button {
                        settings.terminal.fontSizeOffset = TerminalSettings.clamp(settings.terminal.fontSizeOffset - 1)
                    } label: {
                        Label("Smaller", systemImage: "textformat.size.smaller")
                    }
                    .disabled(!canDecrease)

                    Text(offsetLabel)
                        .monospacedDigit()
                        .frame(minWidth: 32)
                        .multilineTextAlignment(.center)

                    Button {
                        settings.terminal.fontSizeOffset = TerminalSettings.clamp(settings.terminal.fontSizeOffset + 1)
                    } label: {
                        Label("Larger", systemImage: "textformat.size.larger")
                    }
                    .disabled(!canIncrease)

                    Spacer()

                    Button("Reset") {
                        settings.terminal.fontSizeOffset = 0
                    }
                    .disabled(settings.terminal.fontSizeOffset == 0)
                }
            } header: {
                Text("Terminal Font Size")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Currently \(currentDisplayPointSize) pt on this display.")
                    Text("The font size adjusts automatically per display so physical size stays consistent. Use ⌘= / ⌘- / ⌘0 to adjust quickly.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }

            Picker("Cursor Style", selection: $settings.terminal.cursorStyle) {
                Text("Block").tag("block")
                Text("Bar").tag("bar")
                Text("Underline").tag("underline")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Theme Settings

private struct ThemeSettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var themeManager: ThemeManager

    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                ForEach(themeManager.availableThemes) { theme in
                    HStack {
                        Image(systemName: settings.activeThemeID == theme.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(settings.activeThemeID == theme.id
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                            if let author = theme.author {
                                Text(author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !BuiltInThemes.ids.contains(theme.id) {
                            Button(role: .destructive) {
                                try? themeManager.deleteTheme(theme.id)
                                settings.activeThemeID = themeManager.activeTheme.id
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete theme")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        settings.activeThemeID = theme.id
                        themeManager.setActiveTheme(theme.id)
                    }
                }
            } header: {
                Text("Themes")
            }

            Section {
                Button("Import Theme…") { importTheme() }
                Button("Restore Built-in Themes") {
                    themeManager.resetBuiltIns()
                    settings.activeThemeID = themeManager.activeTheme.id
                }
                Text("Theme files are stored as YAML in ~/.treemux/themes/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let importError {
                Section {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if !themeManager.loadErrors.isEmpty {
                Section {
                    ForEach(themeManager.loadErrors, id: \.fileName) { err in
                        Label("\(err.fileName): \(err.message)",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                } header: {
                    Text("Theme Load Errors")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try themeManager.importTheme(from: url)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - SSH Settings

private struct SSHSettingsView: View {
    @Binding var settings: AppSettings

    @State private var entries: [ManagedSSHEntry] = []
    @State private var editSheet: SSHServerEditSheet.Mode?
    @State private var showRawEditor = false
    @State private var pendingDelete: ManagedSSHEntry?
    @State private var deleteError: String?

    private var service: SSHConfigService {
        SSHConfigService(configPaths: settings.ssh.configPaths)
    }

    private var primaryPath: String {
        ((settings.ssh.configPaths.first ?? "~/.ssh/config") as NSString).expandingTildeInPath
    }

    var body: some View {
        Form {
            Section("SSH Servers") {
                if entries.isEmpty {
                    Text("No SSH hosts found")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    serverRow(entry)
                }
                Button {
                    editSheet = .add
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }

            Section("SSH Config Paths") {
                ForEach(settings.ssh.configPaths.indices, id: \.self) { index in
                    TextField("Path", text: $settings.ssh.configPaths[index])
                }
            }

            Section("Advanced") {
                Button("Edit Raw Config File…") { showRawEditor = true }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .sheet(item: $editSheet) { mode in
            SSHServerEditSheet(
                mode: mode,
                existingAliases: entries.map { $0.draft.alias },
                service: service
            ) { _ in
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showRawEditor, onDismiss: { Task { await reload() } }) {
            SSHRawConfigSheet(path: primaryPath)
        }
        .confirmationDialog(
            "Delete this server?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await service.remove(alias: entry.draft.alias, atSourcePath: entry.sourcePath)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                    await reload()
                }
            }
        }
        .alert("Delete failed",
               isPresented: Binding(get: { deleteError != nil },
                                    set: { if !$0 { deleteError = nil } }),
               presenting: deleteError) { _ in
            Button("OK", role: .cancel) { }
        } message: { msg in
            Text(verbatim: msg)
        }
    }

    @ViewBuilder
    private func serverRow(_ entry: ManagedSSHEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.draft.alias)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isEditable {
                Button("Edit") { editSheet = .edit(entry) }
                    .buttonStyle(.borderless)
                Button(role: .destructive) { pendingDelete = entry } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            } else {
                Text("Read-only · edit in raw file")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(entry.isEditable ? 1 : 0.55)
    }

    private func subtitle(for entry: ManagedSSHEntry) -> String {
        let d = entry.draft
        let host = d.hostName.isEmpty ? d.alias : d.hostName
        var parts: [String] = []
        if !d.user.isEmpty { parts.append("\(d.user)@\(host)") } else { parts.append(host) }
        if d.port != 22 { parts.append("Port \(d.port)") }
        if !d.identityFile.isEmpty { parts.append(d.identityFile) }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        entries = await service.loadManagedEntries()
    }
}

// MARK: - Shortcuts Settings

private struct ShortcutsSettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            ForEach(ShortcutCategory.allCases.filter { cat in
                ShortcutAction.allCases.contains { $0.category == cat }
            }) { category in
                Section(LocalizedStringKey(category.title)) {
                    let actions = ShortcutAction.allCases.filter { $0.category == category }
                    ForEach(actions) { action in
                        ShortcutRow(action: action, settings: $settings)
                    }
                }
            }

            Section {
                Button("Reset All to Defaults") {
                    TreemuxKeyboardShortcuts.resetAll(in: &settings)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var settings: AppSettings

    private var state: ShortcutState {
        TreemuxKeyboardShortcuts.state(for: action, in: settings)
    }

    private var effectiveShortcut: StoredShortcut? {
        TreemuxKeyboardShortcuts.effectiveShortcut(for: action, in: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(action.title))
                        .font(.system(size: 13))
                    Text(LocalizedStringKey(action.subtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ShortcutRecorderButton(
                    shortcut: Binding(
                        get: { effectiveShortcut },
                        set: { newShortcut in
                            if let shortcut = newShortcut {
                                TreemuxKeyboardShortcuts.setShortcut(shortcut, for: action, in: &settings)
                            }
                        }
                    ),
                    emptyTitle: String(localized: "Not Set")  // NSButton requires String
                )
                .frame(width: 120)
            }

            HStack(spacing: 8) {
                if state == .custom {
                    Button("Reset") {
                        TreemuxKeyboardShortcuts.resetShortcut(for: action, in: &settings)
                    }
                    .font(.system(size: 11))
                }

                if state != .disabled {
                    Button("Disable") {
                        TreemuxKeyboardShortcuts.disableShortcut(for: action, in: &settings)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Update Settings

private struct UpdateSettingsView: View {
    @Binding var settings: AppSettings

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates",
                       isOn: $settings.updates.automaticallyChecksForUpdates)

                Toggle("Automatically download updates",
                       isOn: $settings.updates.automaticallyDownloadsUpdates)
                    .disabled(!settings.updates.automaticallyChecksForUpdates)
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }

                Button("Check for Updates…") {
                    AppUpdaterController.shared.checkForUpdates()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sidebar Icons Settings

private struct SidebarIconsSettingsView: View {
    @Binding var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    /// Repository workspaces (non-archived) for the instance-level icon list.
    private var repositoryWorkspaces: [WorkspaceModel] {
        store.workspaces.filter { !$0.isArchived && $0.kind == .repository }
    }

    var body: some View {
        Form {
            // Global default: Terminal only
            Section("Default") {
                SidebarIconEditorCard(
                    title: "Terminal",
                    subtitle: "Default icon for local terminals",
                    icon: $settings.defaultLocalTerminalIcon,
                    randomizer: SidebarItemIcon.random
                )
            }

            // Per-repository instance icons
            ForEach(repositoryWorkspaces) { workspace in
                Section(workspace.name) {
                    // Workspace icon row
                    WorkspaceIconRow(workspace: workspace)

                    // Worktree icon rows
                    ForEach(workspace.worktrees) { worktree in
                        WorktreeIconRow(workspace: workspace, worktree: worktree)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A clickable row showing a workspace's current icon. Tapping opens the customization sheet.
private struct WorkspaceIconRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        Button {
            store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                target: .workspace(workspace.id)
            )
        } label: {
            HStack(spacing: 10) {
                SidebarItemIconView(icon: store.sidebarIcon(for: workspace), size: 22)
                Text(workspace.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A clickable row showing a worktree's current icon. Tapping opens the customization sheet.
private struct WorktreeIconRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var workspace: WorkspaceModel
    let worktree: WorktreeModel

    var body: some View {
        Button {
            store.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                target: .worktree(workspaceID: workspace.id, worktreePath: worktree.path.path)
            )
        } label: {
            HStack(spacing: 10) {
                SidebarItemIconView(icon: store.sidebarIcon(for: worktree, in: workspace), size: 18)
                    .padding(.leading, 12)
                Text(worktree.branch ?? worktree.path.lastPathComponent)
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
