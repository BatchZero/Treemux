//
//  AIActivityHintsSettingsView.swift
//  Treemux
//

import SwiftUI

struct AIActivityHintsSettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var store: WorkspaceStore
    @State private var rows: [HintRow] = []
    @State private var isLoading = true
    @State private var lastError: String?

    struct HintRow: Identifiable {
        let id: String   // "<targetID>:<kind>"
        let target: HookTarget
        let provider: AIHookProvider
        var status: HookStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Show AI activity in sidebar", isOn: $settings.aiActivityHintsEnabled)
                .padding(.bottom, 4)

            if settings.aiActivityHintsEnabled {
                Divider()

                if isLoading {
                    ProgressView("Inspecting hook status…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else if rows.isEmpty {
                    Text("No AI agents detected. Run claude, codex, or opencode at least once on this machine to see install options.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    rowList
                }

                if let lastError {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .task {
            await refresh()
        }
    }

    private var rowList: some View {
        let grouped = Dictionary(grouping: rows, by: { $0.target.id })
        let groupKeys = grouped.keys.sorted { lhs, rhs in
            // local first, then alphabetical
            if lhs == "local" { return true }
            if rhs == "local" { return false }
            return lhs < rhs
        }

        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groupKeys, id: \.self) { key in
                groupView(
                    title: key == "local" ? String(localized: "Local") : String(key.dropFirst("remote:".count)),
                    rows: grouped[key] ?? []
                )
            }
        }
    }

    private func groupView(title: String, rows: [HintRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(rows) { row in
                hintRowView(row)
            }
        }
    }

    private func hintRowView(_ row: HintRow) -> some View {
        HStack(spacing: 8) {
            statusIcon(for: row.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.provider.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(statusText(for: row.status))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButtons(for: row)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func statusIcon(for status: HookStatus) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .installedOutdated:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
        case .tampered:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .detectedNotInstalled:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .notDetected:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func statusText(for status: HookStatus) -> LocalizedStringKey {
        switch status {
        case .installed:           return "Installed"
        case .installedOutdated:   return "Update available"
        case .tampered:            return "Modified by user"
        case .detectedNotInstalled: return "Not installed"
        case .unknown(let r):      return LocalizedStringKey("Unknown: \(r)")
        case .notDetected:         return "Not detected"
        }
    }

    @ViewBuilder
    private func actionButtons(for row: HintRow) -> some View {
        switch row.status {
        case .detectedNotInstalled:
            Button("Install") { Task { await install(row) } }
        case .installed:
            Button("Reinstall") { Task { await install(row) } }
            Button("Remove") { Task { await uninstall(row) } }
        case .installedOutdated:
            Button("Update") { Task { await install(row) } }
            Button("Remove") { Task { await uninstall(row) } }
        case .tampered:
            Button("Repair") { Task { await install(row) } }
            Button("Remove") { Task { await uninstall(row) } }
        case .unknown, .notDetected:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func refresh() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let targets = collectTargets()
        let installer = AIHookInstaller()
        var newRows: [HintRow] = []
        for target in targets {
            let fs: AIHookFileSystem
            switch target {
            case .local: fs = LocalHookFileSystem()
            case .remote(let t): fs = RemoteHookFileSystem(target: t)
            }
            let results = await installer.inspectAll(fs: fs)
            for (provider, status) in results {
                // Hide rows for which the agent isn't even detected.
                guard status != .notDetected else { continue }
                newRows.append(HintRow(
                    id: "\(target.id):\(provider.kind.rawValue)",
                    target: target,
                    provider: provider,
                    status: status
                ))
            }
        }
        rows = newRows
    }

    private func collectTargets() -> [HookTarget] {
        var out: [HookTarget] = [.local]
        // Collect remote SSH targets from the workspace store
        var seenIDs: Set<String> = ["local"]
        for ws in store.workspaces {
            if let sshTarget = ws.sshTarget {
                let target = HookTarget.remote(sshTarget)
                if !seenIDs.contains(target.id) {
                    out.append(target)
                    seenIDs.insert(target.id)
                }
            }
        }
        return out
    }

    private func install(_ row: HintRow) async {
        lastError = nil
        let installer = AIHookInstaller()
        let fs: AIHookFileSystem = {
            switch row.target {
            case .local: return LocalHookFileSystem()
            case .remote(let t): return RemoteHookFileSystem(target: t)
            }
        }()
        do {
            _ = try await installer.install(row.provider.kind, fs: fs)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func uninstall(_ row: HintRow) async {
        lastError = nil
        let installer = AIHookInstaller()
        let fs: AIHookFileSystem = {
            switch row.target {
            case .local: return LocalHookFileSystem()
            case .remote(let t): return RemoteHookFileSystem(target: t)
            }
        }()
        do {
            try await installer.uninstall(row.provider.kind, fs: fs)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
