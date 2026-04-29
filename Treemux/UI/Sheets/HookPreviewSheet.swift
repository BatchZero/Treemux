//
//  HookPreviewSheet.swift
//  Treemux
//

import SwiftUI

/// Data backing the diff-preview sheet shown before applying an AI-hook install.
/// `onApply` performs the actual install when the user confirms.
struct HookPreviewModel: Identifiable {
    let id = UUID()
    let kind: AIToolKind
    let target: HookTarget
    let displayName: String
    let changes: [HookInstallChange]
    /// Async closure invoked when the user confirms.
    let onApply: () async -> Void
}

/// Side-by-side "before / after" diff sheet for hook installs. Renders one
/// section per `HookInstallChange`; the user reviews the proposed writes and
/// either cancels or invokes `onApply`.
struct HookPreviewSheet: View {
    let model: HookPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var applyError: String?

    private enum BackupState: Equatable {
        case idle
        case inProgress
        case success(URL)
        case failure(String)
    }

    @State private var backupStates: [String: BackupState] = [:]
    private let backupService = HookBackupService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(model.displayName)")
                .font(.title2.bold())
            Text("The following file changes will be made:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.changes, id: \.path) { change in
                        changeView(change)
                    }
                }
                .padding(.vertical, 4)
            }

            if let applyError {
                Text(applyError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    isApplying = true
                    Task {
                        await model.onApply()
                        isApplying = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 800, minHeight: 500)
    }

    private func changeView(_ change: HookInstallChange) -> some View {
        let diff = HookDiff.compute(current: change.current, proposed: change.proposed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(change.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                backupControl(for: change)
            }
            HStack(alignment: .top, spacing: 8) {
                diffColumn(title: "Before", lines: diff.before, side: .before)
                diffColumn(title: "After",  lines: diff.after,  side: .after)
            }
            .frame(minHeight: 180, idealHeight: 220)
            failureMessage(for: change)
        }
    }

    private enum DiffSide { case before, after }

    private func diffColumn(title: LocalizedStringKey, lines: [DiffLine], side: DiffSide) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        diffLineRow(line, side: side)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func diffLineRow(_ line: DiffLine, side: DiffSide) -> some View {
        let prefix: String = {
            switch line.mark {
            case .unchanged: return "  "
            case .removed:   return "- "
            case .added:     return "+ "
            }
        }()
        let bg: Color = {
            switch line.mark {
            case .unchanged: return .clear
            case .removed:   return Color.red.opacity(0.18)
            case .added:     return Color.green.opacity(0.18)
            }
        }()
        let fg: Color = {
            switch line.mark {
            case .unchanged: return .primary
            case .removed:   return .red
            case .added:     return .green
            }
        }()
        Text(prefix + line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(bg)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func backupControl(for change: HookInstallChange) -> some View {
        let state = backupStates[change.path] ?? .idle
        switch state {
        case .idle:
            Button("Backup") { triggerBackup(change) }
                .disabled(change.current == nil)
                .help(change.current == nil
                      ? Text("Nothing to back up (new file)")
                      : Text("Save the current file to ~/.treemux/backups/"))
        case .inProgress:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Backing up…").font(.caption)
            }
        case .success(let url):
            HStack(spacing: 6) {
                Text("Backed up ✓").font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .failure:
            // Failure restores the Backup button; the message renders below
            // the diff in `failureMessage(for:)`.
            Button("Backup") { triggerBackup(change) }
        }
    }

    private func triggerBackup(_ change: HookInstallChange) {
        backupStates[change.path] = .inProgress
        Task { @MainActor in
            do {
                let result = try await backupService.backup(
                    change: change,
                    target: model.target,
                    provider: providerForCurrentChange(change) ?? ClaudeCodeHookProvider()
                )
                backupStates[change.path] = .success(result.localPath)
            } catch {
                backupStates[change.path] = .failure(error.localizedDescription)
            }
        }
    }

    private func providerForCurrentChange(_ change: HookInstallChange) -> AIHookProvider? {
        AIHookProviderRegistry.providers().first { $0.kind == model.kind }
    }

    @ViewBuilder
    private func failureMessage(for change: HookInstallChange) -> some View {
        if case .failure(let msg) = backupStates[change.path] ?? .idle {
            Text("Backup failed: \(msg)")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        } else {
            EmptyView()
        }
    }
}
