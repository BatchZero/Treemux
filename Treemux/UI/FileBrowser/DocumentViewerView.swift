//
//  DocumentViewerView.swift
//  Treemux

import SwiftUI

/// Source / Split / Render container for renderable documents (Markdown, HTML).
/// Hosts a segmented mode picker and a debounced live-preview render side.
struct DocumentViewerView: View {
    let subTabID: UUID
    let path: String
    let content: String
    let encoding: String.Encoding
    let dirty: Bool
    let kind: RenderKind
    let controller: FileBrowserTabController

    /// Currently selected display mode. Initialised from the sub-tab's persisted
    /// value (if any), otherwise from RenderedDocumentPolicy's default for the kind.
    @State private var mode: FileViewMode

    /// Copy of `content` that is updated after a 300 ms debounce so the render
    /// side is not re-rendered on every keystroke.
    @State private var debouncedContent: String

    /// Held reference to the in-flight debounce task so it can be cancelled when
    /// new content arrives before the delay elapses.
    @State private var debounceTask: Task<Void, Never>?

    init(
        subTabID: UUID,
        path: String,
        content: String,
        encoding: String.Encoding,
        dirty: Bool,
        kind: RenderKind,
        controller: FileBrowserTabController
    ) {
        self.subTabID = subTabID
        self.path = path
        self.content = content
        self.encoding = encoding
        self.dirty = dirty
        self.kind = kind
        self.controller = controller

        // Prefer the persisted mode for this sub-tab; fall back to policy default.
        let persisted = controller.subTabs.first(where: { $0.id == subTabID })?.viewMode
        _mode = State(initialValue: persisted ?? RenderedDocumentPolicy.defaultMode(for: kind))
        _debouncedContent = State(initialValue: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            Divider()
            viewContent(for: mode)
        }
        // Kick off the debounce timer whenever the outer content binding changes.
        .onChange(of: content) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
                guard !Task.isCancelled else { return }
                await MainActor.run { debouncedContent = newValue }
            }
        }
    }

    // MARK: - Subviews

    private var modePicker: some View {
        Picker("View Mode", selection: $mode) {
            Text("Source").tag(FileViewMode.source)
            Text("Split").tag(FileViewMode.split)
            Text("Render").tag(FileViewMode.render)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(6)
        // Persist the chosen mode back to the controller so pinned tabs remember it.
        .onChange(of: mode) { _, newMode in
            controller.setViewMode(newMode, forSubTab: subTabID)
        }
    }

    @ViewBuilder
    private func viewContent(for mode: FileViewMode) -> some View {
        switch mode {
        case .source:
            sourceEditor
        case .render:
            renderedSide
        case .split:
            HSplitView {
                sourceEditor
                renderedSide
            }
        }
    }

    /// The source editor — uses the real TextEditorView init signature.
    private var sourceEditor: some View {
        TextEditorView(
            subTabID: subTabID,
            path: path,
            content: content,
            encoding: encoding,
            dirty: dirty,
            controller: controller
        )
    }

    /// The render side — reads the debounced content to avoid rerendering every keystroke.
    @ViewBuilder
    private var renderedSide: some View {
        switch kind {
        case .markdown:
            RenderedMarkdownView(content: debouncedContent)
        case .html:
            HardenedWebView(html: debouncedContent)
        }
    }
}
