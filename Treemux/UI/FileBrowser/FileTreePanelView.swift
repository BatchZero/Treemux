//
//  FileTreePanelView.swift
//  Treemux

import SwiftUI

struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController

    var body: some View {
        VStack(spacing: 0) {
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
        .onTapGesture {
            if node.isDirectory {
                Task { await controller.toggleExpand(node.path) }
            } else {
                Task { await controller.selectFile(node.path) }
            }
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
