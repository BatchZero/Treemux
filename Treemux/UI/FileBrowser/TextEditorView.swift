//
//  TextEditorView.swift
//  Treemux

import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import SwiftUI

struct TextEditorView: View {
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorRepresentable(path: path,
                                    content: content,
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

/// Bridges the file-browser viewer state to ``CodeEditSourceEditor.SourceEditor``.
///
/// The wrapper owns a local `String` mirror of the controller's buffer so
/// `SourceEditor` can take a `Binding<String>`. Outgoing edits are forwarded
/// to the controller via `onChange`; incoming buffer swaps (e.g. switching
/// sub-tabs, reverting on save) are detected by comparing `path` / `content`
/// against the cached values inside the SwiftUI view's `Coordinator`.
private struct CodeEditorRepresentable: View {
    let path: String
    let content: String
    let onChange: (String) -> Void

    @State private var text: String
    @State private var editorState: SourceEditorState = .init()

    init(path: String, content: String, onChange: @escaping (String) -> Void) {
        self.path = path
        self.content = content
        self.onChange = onChange
        self._text = State(initialValue: content)
    }

    var body: some View {
        SourceEditor(
            Binding<String>(
                get: { text },
                set: { newValue in
                    text = newValue
                    onChange(newValue)
                }
            ),
            language: language,
            configuration: configuration,
            state: $editorState
        )
        // When the sub-tab swaps the underlying file or content (e.g. activating
        // a different sub-tab, or saving / reloading), refresh the editor's
        // buffer without re-emitting onChange.
        .onChange(of: path) { _, _ in
            if text != content { text = content }
        }
        .onChange(of: content) { _, newValue in
            if text != newValue { text = newValue }
        }
    }

    // MARK: - Language / size guard

    /// Files larger than this open without tree-sitter highlighting.
    private static let highlightSizeLimit: Int = 2 * 1024 * 1024

    private var fileSizeBytes: Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? 0
    }

    private var shouldHighlight: Bool {
        guard FileTypeClassifier.language(forPath: path) != nil else { return false }
        return fileSizeBytes <= Self.highlightSizeLimit
    }

    private var language: CodeLanguage {
        guard shouldHighlight, let lang = FileTypeClassifier.language(forPath: path) else {
            return .default
        }
        switch lang {
        case .swift: return .swift
        case .javascript: return .javascript
        case .typescript: return .typescript
        case .tsx: return .tsx
        case .python: return .python
        case .go: return .go
        case .rust: return .rust
        case .json: return .json
        case .yaml: return .yaml
        case .markdown: return .markdown
        case .html: return .html
        case .css: return .css
        case .bash: return .bash
        }
    }

    // MARK: - Editor configuration

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TreemuxEditorTheme.system,
                useThemeBackground: true,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                wrapLines: false,
                tabWidth: 4
            ),
            behavior: .init(),
            layout: .init(),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }
}

/// A neutral editor theme that reads adequately in both light and dark mode.
/// Treemux doesn't yet ship a theme system; the colors lean on
/// `NSColor` semantics so they auto-adapt to the system appearance.
private enum TreemuxEditorTheme {
    static var system: EditorTheme {
        EditorTheme(
            text: .init(color: .labelColor),
            insertionPoint: .labelColor,
            invisibles: .init(color: .quaternaryLabelColor),
            background: .textBackgroundColor,
            lineHighlight: .selectedTextBackgroundColor.withSystemEffect(.disabled),
            selection: .selectedTextBackgroundColor,
            keywords: .init(color: .systemPink, bold: true),
            commands: .init(color: .systemBlue),
            types: .init(color: .systemTeal),
            attributes: .init(color: .systemTeal),
            variables: .init(color: .labelColor),
            values: .init(color: .systemOrange),
            numbers: .init(color: .systemOrange),
            strings: .init(color: .systemRed),
            characters: .init(color: .systemRed),
            comments: .init(color: .secondaryLabelColor, italic: true)
        )
    }
}
