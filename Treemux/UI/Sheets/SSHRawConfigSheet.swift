//
//  SSHRawConfigSheet.swift
//  Treemux
//

import SwiftUI

/// Advanced raw-text editor for the primary SSH config file. Saves atomically
/// via the shared writer (same fidelity / permission guarantees).
struct SSHRawConfigSheet: View {
    let path: String                 // expanded absolute path
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Edit Raw Config File").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 520, minHeight: 360)
                .border(.quaternary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
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
