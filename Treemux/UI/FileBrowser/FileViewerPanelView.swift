//
//  FileViewerPanelView.swift
//  Treemux

import SwiftUI

struct FileViewerPanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        Group {
            switch controller.openFile {
            case .empty:
                EmptyViewerState(rootPath: controller.rootPath)
            case .loadingMeta(let p), .loadingContent(let p):
                LoadingViewerState(path: p)
            case .confirmingLargeFile(let path, let size):
                LargeFileConfirmView(path: path, sizeBytes: size,
                                     onConfirm: { Task { await controller.confirmLargeFileLoad() } },
                                     onCancel: { controller.cancelLargeFileLoad() })
            case .text(let path, let content, let encoding, let dirty):
                TextEditorView(path: path, content: content, encoding: encoding, dirty: dirty, controller: controller)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
