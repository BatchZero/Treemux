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
        VStack(alignment: .leading, spacing: 6) {
            Text(change.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                column(title: "Before", text: change.current ?? String(localized: "(file does not exist)"))
                column(title: "After", text: change.proposed)
            }
            .frame(minHeight: 180, idealHeight: 220)
        }
    }

    private func column(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
    }
}
