//
//  FileViewerPanelView.swift
//  Treemux

import SwiftUI

struct FileViewerPanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            if !controller.subTabs.isEmpty {
                FileSubTabBarView(controller: controller)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // GutterView is `addFloatingSubview`-attached to NSScrollView
                // without layer clipping, so without this the line numbers
                // leak above the sub-tab bar into the window toolbar.
                .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Renders every sub-tab's viewer in a ZStack and toggles visibility via
    /// `.opacity` + `.allowsHitTesting`. Keeping inactive editors alive (rather
    /// than tearing them down with `.id(activeSubTabID)`) preserves each
    /// sub-tab's NSTextView, undo stack, cursor, scroll, and find-panel state
    /// independently. CodeEditSourceEditor 0.15.x clears the undo stack inside
    /// `TextView.setTextStorage` on every controller rebuild, so an
    /// "external storage + same undoManager" approach cannot preserve undo
    /// across rebuilds. ZStack avoids the rebuild entirely.
    @ViewBuilder
    private var content: some View {
        if controller.subTabs.isEmpty {
            EmptyViewerState(rootPath: controller.rootPath)
        } else {
            ZStack {
                ForEach(controller.subTabs) { subTab in
                    subTabContent(subTab)
                        .opacity(subTab.id == controller.activeSubTabID ? 1 : 0)
                        .allowsHitTesting(subTab.id == controller.activeSubTabID)
                }
            }
        }
    }

    @ViewBuilder
    private func subTabContent(_ subTab: SubTabRuntime) -> some View {
        switch subTab.openFile {
        case .empty:
            EmptyViewerState(rootPath: controller.rootPath)
        case .loadingMeta(let p), .loadingContent(let p):
            LoadingViewerState(path: p)
        case .confirmingLargeFile(let path, let size):
            LargeFileConfirmView(path: path, sizeBytes: size,
                                 onConfirm: { Task { await controller.confirmLargeFileLoad() } },
                                 onCancel: { controller.cancelLargeFileLoad() })
        case .text(let path, let content, let encoding, let dirty):
            // Route renderable file types (Markdown, HTML) to DocumentViewerView;
            // fall back to plain TextEditorView for everything else.
            if let kind = RenderedDocumentPolicy.renderKind(forPath: path) {
                DocumentViewerView(subTabID: subTab.id, path: path, content: content,
                                   encoding: encoding, dirty: dirty, kind: kind,
                                   controller: controller)
            } else {
                TextEditorView(subTabID: subTab.id, path: path, content: content,
                               encoding: encoding, dirty: dirty, controller: controller)
            }
        case .image(let path, let img):
            ImagePreviewView(path: path, image: img)
        case .quickLook(let path, let url):
            QuickLookViewerView(path: path, url: url)
        case .binary(let path, let meta):
            BinaryInfoView(path: path, metadata: meta)
        case .error(let path, let msg):
            ErrorViewerState(path: path, message: msg)
        }
    }
}

private struct EmptyViewerState: View {
    let rootPath: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36))
            Text(LocalizedStringKey("Select a file from the tree"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoadingViewerState: View {
    let path: String
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorViewerState: View {
    let path: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
