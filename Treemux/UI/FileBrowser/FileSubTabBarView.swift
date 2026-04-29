//
//  FileSubTabBarView.swift
//  Treemux

import SwiftUI

/// Horizontal bar of sub-tabs inside a file-browser tab. Each entry corresponds
/// to a `SubTabRuntime` on the controller. Active tab gets a bottom accent
/// stripe; preview (unpinned) tabs render their title in italic. Hover reveals
/// a close affordance; right-click exposes copy-path and close-set commands;
/// drag reorders.
struct FileSubTabBarView: View {
    @ObservedObject var controller: FileBrowserTabController
    @State private var hoveredID: UUID?
    @State private var draggedID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(controller.subTabs) { tab in
                    SubTabButton(
                        tab: tab,
                        isActive: tab.id == controller.activeSubTabID,
                        isHovered: hoveredID == tab.id,
                        isDirty: dirtyState(for: tab),
                        rootPath: controller.rootPath,
                        onSelect: { controller.activateSubTab(tab.id) },
                        onClose: { controller.closeSubTab(tab.id) },
                        onCopyAbsolute: { controller.copyPath(tab.path, mode: .absolute) },
                        onCopyRelative: { controller.copyPath(tab.path, mode: .relative) },
                        onPin: { controller.pinActiveSubTab() },
                        onCloseOthers: { closeAllExcept(tab.id) },
                        onCloseAll: { closeAll() }
                    )
                    .onHover { hoveredID = $0 ? tab.id : nil }
                    .onDrag {
                        draggedID = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: SubTabDropDelegate(
                        targetID: tab.id,
                        controller: controller,
                        draggedID: $draggedID
                    ))
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 32)
        .background(.thickMaterial)
    }

    private func dirtyState(for tab: SubTabRuntime) -> Bool {
        if case .text(_, _, _, let dirty) = tab.openFile { return dirty }
        return false
    }

    private func closeAllExcept(_ id: UUID) {
        let toClose = controller.subTabs.filter { $0.id != id }.map(\.id)
        toClose.forEach(controller.closeSubTab)
    }

    private func closeAll() {
        controller.subTabs.map(\.id).forEach(controller.closeSubTab)
    }
}

// MARK: - Drop delegate

private struct SubTabDropDelegate: DropDelegate {
    let targetID: UUID
    let controller: FileBrowserTabController
    @Binding var draggedID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let from = draggedID,
              from != targetID,
              let i = controller.subTabs.firstIndex(where: { $0.id == from }),
              let j = controller.subTabs.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            controller.reorderSubTabs(
                from: IndexSet(integer: i),
                to: j > i ? j + 1 : j
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Sub-tab button

private struct SubTabButton: View {
    let tab: SubTabRuntime
    let isActive: Bool
    let isHovered: Bool
    let isDirty: Bool
    let rootPath: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCopyAbsolute: () -> Void
    let onCopyRelative: () -> Void
    let onPin: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(URL(fileURLWithPath: tab.path).lastPathComponent)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .italic(!tab.isPinned)
                    .foregroundStyle(isActive ? .primary : .secondary)
                if isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                if isHovered || isActive {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isActive ? AnyShapeStyle(.white.opacity(0.12))
                : isHovered ? AnyShapeStyle(.white.opacity(0.06))
                : AnyShapeStyle(Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(LocalizedStringKey("Copy Absolute Path")) { onCopyAbsolute() }
            Button(LocalizedStringKey("Copy Relative Path")) { onCopyRelative() }
            Divider()
            if !tab.isPinned {
                Button(LocalizedStringKey("Pin Tab")) { onPin() }
            }
            Button(LocalizedStringKey("Close Tab")) { onClose() }
            Button(LocalizedStringKey("Close Other Tabs")) { onCloseOthers() }
            Button(LocalizedStringKey("Close All Tabs")) { onCloseAll() }
        }
    }

    private var iconName: String {
        switch FileTypeClassifier.classifyByName(tab.path) {
        case .text: return "doc.text"
        case .image: return "photo"
        case .quickLook: return "doc.richtext"
        case .binary, .unknown: return "doc"
        }
    }
}
