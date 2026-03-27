//
//  WorkspaceTabBarView.swift
//  Treemux

import SwiftUI

/// Tab bar displayed above the terminal area when 2+ tabs exist.
/// Shows tab buttons with title, pane count badge, close button, and drag-to-reorder.
struct WorkspaceTabBarView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var renamingTabID: UUID?
    @State private var renameText: String = ""
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.tabs) { tab in
                        if renamingTabID == tab.id {
                            TabRenameField(
                                text: $renameText,
                                onCommit: {
                                    workspace.renameTab(tab.id, title: renameText)
                                    renamingTabID = nil
                                },
                                onCancel: {
                                    renamingTabID = nil
                                }
                            )
                            .frame(width: TreemuxTabSizing.width(for: renameText.isEmpty ? "Tab name" : renameText, paneCount: paneCount(for: tab)))
                        } else {
                            TabButton(
                                tab: tab,
                                isSelected: tab.id == workspace.activeTabID,
                                isHovered: hoveredTabID == tab.id,
                                paneCount: paneCount(for: tab),
                                onSelect: { workspace.selectTab(tab.id) },
                                onClose: { workspace.closeTab(tab.id) },
                                onRename: {
                                    renameText = tab.title
                                    renamingTabID = tab.id
                                }
                            )
                            .onHover { isHovered in
                                hoveredTabID = isHovered ? tab.id : nil
                            }
                            .onDrag {
                                draggedTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(
                                targetTabID: tab.id,
                                workspace: workspace,
                                draggedTabID: $draggedTabID
                            ))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // New tab button
            Button {
                workspace.createTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func paneCount(for tab: WorkspaceTabStateRecord) -> Int {
        tab.layout?.paneIDs.count ?? 1
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let tab: WorkspaceTabStateRecord
    let isSelected: Bool
    let isHovered: Bool
    let paneCount: Int
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if paneCount > 1 {
                    Text("\(paneCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isSelected ? .secondary : .tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }

                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(.white.opacity(0.15))
                : isHovered ? AnyShapeStyle(.white.opacity(0.08))
                : AnyShapeStyle(.white.opacity(0.05))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: TreemuxTabSizing.width(for: tab.title, paneCount: paneCount))
        .contextMenu {
            Button("Rename…") { onRename() }
            Divider()
            Button("Close Tab") { onClose() }
        }
    }
}

// MARK: - Rename Field

private struct TabRenameField: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Tab name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .focused($isFocused)
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
            .onAppear { isFocused = true }
    }
}

// MARK: - Tab Sizing

enum TreemuxTabSizing {
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let countFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)

    static func width(for title: String, paneCount: Int) -> CGFloat {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        var totalWidth = titleWidth + 44
        if paneCount > 1 {
            let countText = "\(paneCount)"
            let countWidth = ceil((countText as NSString).size(withAttributes: [.font: countFont]).width)
            totalWidth += countWidth + 12
        }
        return min(max(totalWidth, 100), 260)
    }
}

// MARK: - Drag & Drop

private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let workspace: WorkspaceModel
    @Binding var draggedTabID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedTabID,
              dragged != targetTabID,
              let fromIndex = workspace.tabs.firstIndex(where: { $0.id == dragged }),
              let toIndex = workspace.tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            workspace.moveTab(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
