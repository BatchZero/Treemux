//
//  SSHServerEditSheet.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Shared add/edit form for an SSH server. Presented identically from both the
/// Settings → SSH list and the Open Project → Remote dialog.
struct SSHServerEditSheet: View {
    enum Mode: Equatable {
        case add
        case edit(ManagedSSHEntry)
    }

    let mode: Mode
    /// Aliases already present, for uniqueness validation.
    let existingAliases: [String]
    let service: SSHConfigService
    /// Called after a successful save with the resulting connection target.
    let onSaved: (SSHTarget) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: SSHServerDraft
    @State private var portText: String
    @State private var testResult: LocalizedStringKey?
    @State private var isTesting = false
    @State private var saveError: String?

    init(mode: Mode,
         existingAliases: [String],
         service: SSHConfigService,
         onSaved: @escaping (SSHTarget) -> Void) {
        self.mode = mode
        self.existingAliases = existingAliases
        self.service = service
        self.onSaved = onSaved
        switch mode {
        case .add:
            _draft = State(initialValue: SSHServerDraft(alias: "", hostName: ""))
            _portText = State(initialValue: "22")
        case .edit(let entry):
            _draft = State(initialValue: entry.draft)
            _portText = State(initialValue: String(entry.draft.port))
        }
    }

    private var originalAlias: String? {
        if case .edit(let e) = mode { return e.draft.alias }
        return nil
    }

    private var isValid: Bool {
        let alias = draft.alias.trimmingCharacters(in: .whitespaces)
        let host = draft.hostName.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty, !host.isEmpty,
              // alias and hostName must be single tokens (no internal whitespace
              // or newlines) so they form a valid single Host/HostName directive
              // and cannot inject extra config lines.
              alias.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              // reject wildcard/pattern aliases — those become read-only entries.
              alias.rangeOfCharacter(from: CharacterSet(charactersIn: "*?")) == nil,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let port = Int(portText), (1...65535).contains(port) else { return false }
        let collision = existingAliases.contains { $0 == alias && $0 != originalAlias }
        return !collision
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .add ? "New Server" : "Edit Server")
                .font(.headline)

            Form {
                TextField("Alias (Host)", text: $draft.alias)
                TextField("Host (HostName)", text: $draft.hostName)
                HStack {
                    TextField("User", text: $draft.user)
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                }
                HStack {
                    TextField("Identity File", text: $draft.identityFile)
                    Button("Choose…") { chooseIdentityFile() }
                }
            }
            .formStyle(.grouped)

            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Test Connection") { Task { await testConnection() } }
                    .disabled(isTesting || draft.hostName.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ("~/.ssh" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    private func target(from d: SSHServerDraft) -> SSHTarget {
        // displayName is non-optional in SSHTarget; use alias as the display name.
        SSHTarget(
            host: d.hostName,
            port: Int(portText) ?? 22,
            user: d.user.isEmpty ? nil : d.user,
            identityFile: d.identityFile.isEmpty ? nil : d.identityFile,
            displayName: d.alias,
            remotePath: nil
        )
    }

    private func testConnection() async {
        isTesting = true
        testResult = "Testing…"
        let status = await service.testConnection(target(from: draft))
        switch status {
        case .connected: testResult = "Connected"
        case .authRequired: testResult = "Authentication required"
        case .unreachable: testResult = "Unreachable"
        }
        isTesting = false
    }

    private func save() {
        var toSave = draft
        toSave.alias = draft.alias.trimmingCharacters(in: .whitespaces)
        toSave.hostName = draft.hostName.trimmingCharacters(in: .whitespaces)
        toSave.port = Int(portText) ?? 22
        Task {
            do {
                switch mode {
                case .add:
                    try await service.add(toSave)
                case .edit(let entry):
                    try await service.update(toSave,
                                             originalAlias: entry.draft.alias,
                                             atSourcePath: entry.sourcePath)
                }
                onSaved(target(from: toSave))
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

extension SSHServerEditSheet.Mode: Identifiable {
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let entry): return "edit:\(entry.id)"
        }
    }
}
