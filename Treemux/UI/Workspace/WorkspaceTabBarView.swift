//
//  WorkspaceTabBarView.swift
//  Treemux

import SwiftUI

/// Tab bar displayed above the terminal area when 2+ tabs exist.
/// Shows tab buttons with title, pane count badge, close button, and drag-to-reorder.
struct WorkspaceTabBarView: View {
    @Environment(ThemeManager.self) private var theme
    let workspace: WorkspaceModel
    @State private var renamingTabID: UUID?
    @State private var renameText: String = ""
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?
    @State private var viewportWidth: CGFloat = 0
    @State private var chromeWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var liveScrollX: CGFloat = 0

    private var groups: (files: [WorkspaceTabStateRecord], shell: [WorkspaceTabStateRecord]) {
        TabGrouping.partition(workspace.tabs) { $0.kind }
    }

    private var tabCount: Int { groups.files.count + groups.shell.count }

    private var uniformTabWidth: CGFloat {
        TabBarLayout.uniformWidth(
            viewport: viewportWidth,
            tabCount: tabCount,
            reservedChrome: chromeWidth + Spacing.xs * 2,
            minWidth: TabBarLayout.minTabWidth,
            maxWidth: TabBarLayout.maxTabWidth
        )
    }

    private var maxScrollX: CGFloat { max(0, contentWidth - viewportWidth) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    if !groups.files.isEmpty {
                        TabGroupEyebrow(title: "Files", color: theme.accentColor)
                            .background(chromeWidthReporter)
                        ForEach(groups.files) { tab in tabView(tab) }
                    }
                    if !groups.files.isEmpty && !groups.shell.isEmpty {
                        Rectangle()
                            .fill(theme.dividerColor)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, Spacing.xxs)
                            .background(chromeWidthReporter)
                    }
                    if !groups.shell.isEmpty {
                        TabGroupEyebrow(title: "Shell", color: theme.accentColor)
                            .background(chromeWidthReporter)
                        ForEach(groups.shell) { tab in tabView(tab) }
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: TabBarContentWidthKey.self, value: g.size.width)
                    }
                )
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                liveScrollX = x
            }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TabBarViewportWidthKey.self, value: g.size.width)
                }
            )
            .onPreferenceChange(TabBarViewportWidthKey.self) { viewportWidth = $0 }
            .onPreferenceChange(TabBarContentWidthKey.self) { contentWidth = $0 }
            .onPreferenceChange(TabBarChromeWidthKey.self) { chromeWidth = $0 }
            .overlay(
                ScrollWheelHorizontalRedirect { deltaY in
                    // Wheel down scrolls toward the trailing edge. Sign/step
                    // calibrated during GUI smoke; flip the sign if inverted.
                    let target = min(max(liveScrollX - deltaY * 3, 0), maxScrollX)
                    scrollPosition.scrollTo(x: target)
                }
            )

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
            .padding(.trailing, Spacing.xs)
        }
        .frame(height: 38)
        .background(theme.tabBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)
        }
    }

    // Reports a chrome element's width into TabBarChromeWidthKey (summed).
    private var chromeWidthReporter: some View {
        GeometryReader { g in
            Color.clear.preference(key: TabBarChromeWidthKey.self, value: g.size.width)
        }
    }

    @ViewBuilder
    private func tabView(_ tab: WorkspaceTabStateRecord) -> some View {
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
            .frame(width: uniformTabWidth)
        } else {
            TabButton(
                tab: tab,
                isSelected: tab.id == workspace.activeTabID,
                isHovered: hoveredTabID == tab.id,
                paneCount: paneCount(for: tab),
                isDirty: dirtyState(for: tab),
                dotKind: dotKind(for: tab),
                onSelect: { workspace.selectTab(tab.id) },
                onClose: { workspace.requestCloseTab(tab.id) },
                onCloseOthers: { workspace.requestCloseOtherTabs(keeping: tab.id) },
                onCloseAll: { workspace.requestCloseAllTabs() },
                onRename: {
                    renameText = tab.title
                    renamingTabID = tab.id
                },
                width: uniformTabWidth
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

    private func paneCount(for tab: WorkspaceTabStateRecord) -> Int {
        tab.layout?.paneIDs.count ?? 1
    }

    private func dirtyState(for tab: WorkspaceTabStateRecord) -> Bool {
        guard tab.kind == .fileBrowser else { return false }
        return workspace.fileBrowserController(forTabID: tab.id)?.isDirty ?? false
    }

    private func dotKind(for tab: WorkspaceTabStateRecord) -> TabActivityDot.Kind? {
        let path = workspace.activeWorktreePath
        return workspace.hasRunningSessions(forWorktreePath: path) ? .idle : nil
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    @Environment(ThemeManager.self) private var theme
    let tab: WorkspaceTabStateRecord
    let isSelected: Bool
    let isHovered: Bool
    let paneCount: Int
    let isDirty: Bool
    let dotKind: TabActivityDot.Kind?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAll: () -> Void
    let onRename: () -> Void
    let width: CGFloat

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                // Tab kind icon (folder for file browser, terminal for shell tabs).
                Image(systemName: tab.kind == .fileBrowser ? "folder" : "terminal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .tertiary)
                // Activity dot appears between kind icon and title when a session is running.
                if let dotKind {
                    TabActivityDot(kind: dotKind)
                        .padding(.trailing, 2)
                }
                // Dirty marker for unsaved file-browser edits.
                if isDirty {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 5, height: 5)
                }
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
                isSelected ? AnyShapeStyle(theme.sidebarSelection)
                : isHovered ? AnyShapeStyle(theme.textPrimary.opacity(0.08))
                : AnyShapeStyle(theme.textPrimary.opacity(0.05))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .tabAccentIndicator(theme.accentColor, active: isSelected)
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .contextMenu {
            Button("Rename…") { onRename() }
            Divider()
            Button("Close Tab") { onClose() }
            Button("Close Other Tabs") { onCloseOthers() }
            Button("Close All Tabs") { onCloseAll() }
        }
    }
}

// MARK: - Activity Dot

/// Small leading-edge dot on a `TabButton` indicating an active session.
private struct TabActivityDot: View {
    enum Kind: Equatable { case idle }

    let kind: Kind

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .opacity(0.8)
    }
}

// MARK: - Group Eyebrow

/// Tiny uppercase monospace label marking a tab-kind group ("Files" / "Shell").
private struct TabGroupEyebrow: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(DesignFonts.eyebrow)
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
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
        // The tab bar groups by kind; only allow reordering within the same kind
        // group so a cross-group drag can't silently interleave kinds in the
        // canonical workspace.tabs order.
        guard workspace.tabs[fromIndex].kind == workspace.tabs[toIndex].kind else { return }
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
