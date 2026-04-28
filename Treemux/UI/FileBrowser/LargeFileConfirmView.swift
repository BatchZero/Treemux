//
//  LargeFileConfirmView.swift
//  Treemux

import SwiftUI

struct LargeFileConfirmView: View {
    let path: String
    let sizeBytes: Int64
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var sizeMB: String {
        String(format: "%.1f", Double(sizeBytes) / (1024 * 1024))
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(LocalizedStringKey("Large File"))
                .font(.headline)
            Text("\(URL(fileURLWithPath: path).lastPathComponent) — \(sizeMB) MB")
                .foregroundStyle(.secondary)
            HStack {
                Button(LocalizedStringKey("Cancel"), action: onCancel)
                Button(LocalizedStringKey("Open Anyway"), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
