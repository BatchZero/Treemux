//
//  FileTreePanelView.swift
//  Treemux

import SwiftUI

struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
            FileTreeErrorBanner(controller: controller)
            FileTreeToolbar(controller: controller)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rootChildren, id: \.id) { node in
                        NodeRow(node: node, depth: 0, controller: controller)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                Task { await controller.refresh(controller.rootPath) }
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
                    NodeRow(node: child, depth: depth + 1, controller: controller)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(depth) * 14)
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.25)
                      : isHovered ? Color.primary.opacity(0.06)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // VSCode-style click routing: single-click opens (or replaces) a
        // preview sub-tab; double-click pins. When SwiftUI fires both a
        // single-tap and then a double-tap on a real double-click, the result
        // is still the same — `pinFile` finds the existing preview tab and
        // promotes `isPinned`.
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

    private var iconName: String {
        switch node.kind {
        case .directory: return isExpanded ? "folder.fill" : "folder"
        case .symlink: return "arrow.up.right.square"
        case .file:
            switch FileTypeClassifier.classifyByName(node.name) {
            case .text: return "doc.text"
            case .image: return "photo"
            case .quickLook: return "doc.richtext"
            case .binary: return "doc"
            case .unknown: return "doc"
            }
        }
    }
}
