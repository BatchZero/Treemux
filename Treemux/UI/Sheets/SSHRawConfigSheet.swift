//
//  SSHRawConfigSheet.swift
//  Treemux
//

import SwiftUI

/// Advanced raw-text editor for the primary SSH config file. Saves atomically
/// via the shared writer (same fidelity / permission guarantees).
struct SSHRawConfigSheet: View {
    @EnvironmentObject private var theme: ThemeManager
    let path: String                 // expanded absolute path
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Text("Edit Raw Config File")
                .font(DesignFonts.dialogTitle)
                .tracking(DesignFonts.dialogTitleTracking)
            Text(path).font(DesignFonts.chromeCaption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))   // intentional monospaced: data layer
                .frame(minWidth: 520, minHeight: 360)
                .border(.quaternary)

            if let errorMessage {
                Text(errorMessage).font(DesignFonts.chromeCaption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(UtilityButtonStyle(tint: theme.textSecondary, activeTint: theme.accentColor, border: theme.dividerColor))
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(accent: theme.accentColor, onAccent: theme.onAccentColor))
            }
        }
        .padding(Spacing.lg)
        .frame(width: 600, height: 480)
        .task { load() }
    }

    private func load() {
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func save() {
        do {
            try SSHConfigRawWriter.write(text, to: path)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
