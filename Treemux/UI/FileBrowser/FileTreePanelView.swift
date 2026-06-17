//
//  FileTreePanelView.swift
//  Treemux

import SwiftUI

struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            FileTreeErrorBanner(controller: controller)
            FileTreeToolbar(controller: controller)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rootChildren, id: \.id) { node in
                        NodeRow(node: node, depth: 0, density: store.settings.fileTree.density, controller: controller)
                    }
                    if controller.truncatedDirs.contains(controller.rootPath) {
                        LoadMoreRow(path: controller.rootPath, depth: 0, controller: controller)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(DesignTokens.panel)
    }
}

private struct FileTreeToolbar: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        HStack(spacing: 8) {
            Text(URL(fileURLWithPath: controller.rootPath).lastPathComponent)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                Task { await controller.refreshTree() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Refresh"))

            Button {
                controller.setShowsHiddenFiles(!controller.showsHiddenFiles)
            } label: {
                Image(systemName: controller.showsHiddenFiles ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help(LocalizedStringKey("Toggle Hidden Files"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct FileTreeErrorBanner: View {
    @ObservedObject var controller: FileBrowserTabController
    @State private var password: String = ""

    var body: some View {
        Group {
            switch controller.loadError {
            case .generic(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(2)
                    Spacer()
                    Button(LocalizedStringKey("Retry")) {
                        Task { await controller.loadRoot() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.thickMaterial)

            case .needsPassword(let host):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .foregroundStyle(.orange)
                        Text(String.localizedStringWithFormat(
                            String(localized: "Cannot connect to %@"), host))
                            .font(.system(size: 11, weight: .medium))
                    }
                    HStack(spacing: 6) {
                        SecureField(LocalizedStringKey("Enter Password"), text: $password)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button(LocalizedStringKey("Connect")) {
                            let pw = password
                            password = ""
                            Task { await controller.retryWithPassword(pw) }
                        }
                        .controlSize(.small)
                        .disabled(password.isEmpty)
                    }
                }
                .padding(8)
                .background(.thickMaterial)

            case .none:
                EmptyView()
            }
        }
        // Clear the SecureField whenever loadError transitions, so a rejected
        // password doesn't linger in the field across retry attempts.
        .onChange(of: controller.loadError) { _, _ in
            password = ""
        }
    }
}

private struct NodeRow: View {
    let node: FileNode
    let depth: Int
    let density: TreeDensity
    @ObservedObject var controller: FileBrowserTabController
    @State private var isHovered = false

    private var isSelected: Bool { controller.selectedFilePath == node.path }
    private var isExpanded: Bool { controller.expandedDirs.contains(node.path) }
    private var children: [FileNode]? { controller.childrenByPath[node.path] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded, let kids = children {
                ForEach(kids, id: \.id) { child in
                    NodeRow(node: child, depth: depth + 1, density: density, controller: controller)
                }
                if controller.truncatedDirs.contains(node.path) {
                    LoadMoreRow(path: node.path, depth: depth + 1, controller: controller)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // One hairline per depth level (14pt per level: 1pt line + 13pt trailing).
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(DesignTokens.line)
                    .frame(width: 1, height: density.rowHeight)
                    .padding(.trailing, 13)
            }
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.faint)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            // 4×4 git-status dot (clear placeholder keeps name alignment stable).
            if let status = controller.fileStatusByPath[node.path] {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 4)
            }
            iconView
                .frame(width: density.fontSize + 3, height: density.fontSize + 3)
            Text(node.name)
                .font(DesignFonts.dataLayer(size: density.fontSize))
                .foregroundStyle(DesignTokens.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(height: density.rowHeight)
        .padding(.horizontal, 8)
        // NOTE: these Phosphor tokens are dark-tuned; light-theme support is a
        // later phase (tracked). On the light theme this panel renders dark.
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? DesignTokens.surface
                      : isHovered ? DesignTokens.text.opacity(0.06)
                      : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(DesignTokens.files)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            TapGesture(count: 2).onEnded {
                if !node.isDirectory {
                    Task { await controller.pinFile(node.path) }
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                if node.isDirectory {
                    Task { await controller.toggleExpand(node.path) }
                } else {
                    Task { await controller.openInTree(node.path) }
                }
            }
        )
        .contextMenu {
            Button(LocalizedStringKey("Copy Absolute Path")) {
                controller.copyPath(node.path, mode: .absolute)
            }
            Button(LocalizedStringKey("Copy Relative Path")) {
                controller.copyPath(node.path, mode: .relative)
            }
            .disabled(node.path == controller.rootPath)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        let icon = FileIconCatalog.icon(for: node, isExpanded: isExpanded)
        Image(icon.asset)
            .resizable()
            .renderingMode(icon.isTemplate ? .template : .original)
            .scaledToFit()
            .foregroundStyle(icon.tint ?? DesignTokens.muted)
    }

    private func color(for status: FileStatus) -> Color {
        switch status {
        case .untracked: return .gray
        case .modified, .renamed(_): return .orange
        case .added: return .green
        case .deleted: return .red
        }
    }
}

private struct LoadMoreRow: View {
    let path: String
    let depth: Int
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        Button {
            Task { await controller.loadMore(path) }
        } label: {
            HStack(spacing: 4) {
                // Mirror NodeRow's depth guide lines so "Load more" lines up with siblings.
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(DesignTokens.line)
                        .frame(width: 1, height: 20)
                        .padding(.trailing, 13)
                }
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey("Load more"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}
