//
//  TextEditorView.swift
//  Treemux

import AppKit
import SwiftUI

struct TextEditorView: View {
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            NSTextEditorView(content: content,
                             onChange: { controller.updateBuffer(content: $0) })
            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack {
            Text(URL(fileURLWithPath: path).lastPathComponent)
            if dirty {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            Spacer()
            Text(encodingDisplay).foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    private var encodingDisplay: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .isoLatin1: return "Latin-1"
        default: return "Encoding"
        }
    }
}

private struct NSTextEditorView: NSViewRepresentable {
    let content: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = content
        tv.delegate = context.coordinator

        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let ruler = LineNumberRulerView(textView: tv)
        scroll.verticalRulerView = ruler
        ruler.recomputeLineStarts()

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != content {
            tv.string = content
            (scroll.verticalRulerView as? LineNumberRulerView)?.recomputeLineStarts()
            scroll.verticalRulerView?.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onChange(tv.string)
        }
    }
}
