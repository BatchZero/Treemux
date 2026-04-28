//
//  BinaryInfoView.swift
//  Treemux

import SwiftUI

struct BinaryInfoView: View {
    let path: String
    let metadata: FileMetadata
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("Binary file"))
                .font(.title3.bold())
            HStack { Text(LocalizedStringKey("Path:")); Text(path).foregroundStyle(.secondary) }
            HStack { Text(LocalizedStringKey("Size:")); Text("\(metadata.sizeBytes) bytes").foregroundStyle(.secondary) }
            if let m = metadata.modifiedAt {
                HStack { Text(LocalizedStringKey("Modified:")); Text(m.formatted()).foregroundStyle(.secondary) }
            }
            Button(LocalizedStringKey("Reveal in Finder")) {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
