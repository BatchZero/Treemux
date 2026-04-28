//
//  TextEditorView.swift
//  Treemux

import SwiftUI

struct TextEditorView: View {
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        // Placeholder; replaced with NSTextView-backed editor in Task 7.5.
        VStack {
            Text("Text editor placeholder for \(path)")
            Text("Length: \(content.count) chars, dirty: \(dirty ? "yes" : "no")")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
