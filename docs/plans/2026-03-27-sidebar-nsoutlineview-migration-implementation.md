# Sidebar NSOutlineView Migration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the SwiftUI `List`-based sidebar with an AppKit `NSOutlineView` wrapped in `NSViewRepresentable` to eliminate UI lag and achieve Liney-style rounded selection highlighting.

**Architecture:** A `WorkspaceOutlineSidebar` (NSViewRepresentable) replaces the SwiftUI List inside the existing `WorkspaceSidebarView` shell. A `SidebarCoordinator` manages NSOutlineViewDataSource/Delegate, a custom `SidebarRowView` (NSTableRowView subclass) draws inset rounded selection, and row content is rendered via SwiftUI embedded in `NSHostingView`. Fingerprint-based diffing ensures minimal reloads.

**Tech Stack:** Swift, AppKit (NSOutlineView, NSTableRowView, NSTableCellView, NSScrollView), SwiftUI (NSHostingView, NSViewRepresentable)

**Reference:** Liney's implementation at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift`

---

### Task 1: Add selection theme colors to ThemeManager

**Files:**
- Modify: `Treemux/Domain/ThemeDefinition.swift` — add `sidebarSelectionStroke` to `UIColors`
- Modify: `Treemux/UI/Theme/ThemeManager.swift` — add resolved NSColor properties

**Step 1: Add `sidebarSelectionStroke` to UIColors**

In `Treemux/Domain/ThemeDefinition.swift`, add a new field to the `UIColors` struct:

```swift
struct UIColors: Codable {
    // ... existing fields ...
    let sidebarSelectionStroke: String?  // Optional for backward compat with existing theme files
}
```

Add default values in the `treemuxDark` and `treemuxLight` built-in themes:
- Dark: `sidebarSelectionStroke: "#418ADE"` (same as accentColor)
- Light: use an appropriate accent-coordinated value

**Step 2: Add NSColor properties to ThemeManager**

In `Treemux/UI/Theme/ThemeManager.swift`, add:

```swift
// NSColor versions needed by AppKit row drawing
var sidebarSelectionFillNS: NSColor { NSColor(sidebarSelection) }
var sidebarSelectionStrokeNS: NSColor {
    if let hex = activeTheme.ui.sidebarSelectionStroke {
        return NSColor(Color(hex: hex)).withAlphaComponent(0.9)
    }
    return NSColor(accentColor).withAlphaComponent(0.9)
}
```

**Step 3: Build and verify no compile errors**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```
git add Treemux/Domain/ThemeDefinition.swift Treemux/UI/Theme/ThemeManager.swift
git commit -m "feat: add sidebar selection stroke theme color"
```

---

### Task 2: Create SidebarNodeItem model

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarNodeItem.swift`

**Step 1: Write SidebarNodeItem**

```swift
//
//  SidebarNodeItem.swift
//  Treemux

import Foundation

/// Tree node used by the AppKit NSOutlineView sidebar.
/// Each node wraps either a workspace or a worktree and holds child nodes.
final class SidebarNodeItem: NSObject {
    enum Kind {
        case workspace(WorkspaceModel)
        case worktree(WorkspaceModel, WorktreeModel)
    }

    let kind: Kind
    let children: [SidebarNodeItem]

    init(kind: Kind, children: [SidebarNodeItem] = []) {
        self.kind = kind
        self.children = children
    }

    var nodeID: String {
        switch kind {
        case .workspace(let ws): return ws.id.uuidString
        case .worktree(_, let wt): return wt.id.uuidString
        }
    }

    var workspace: WorkspaceModel? {
        switch kind {
        case .workspace(let ws): return ws
        case .worktree(let ws, _): return ws
        }
    }

    var worktree: WorktreeModel? {
        switch kind {
        case .workspace: return nil
        case .worktree(_, let wt): return wt
        }
    }

    var isExpandable: Bool { !children.isEmpty }

    /// Flattens this node and all descendants into a flat array.
    func flattened() -> [SidebarNodeItem] {
        [self] + children.flatMap { $0.flattened() }
    }

    // MARK: - NSObject identity (required for NSOutlineView item stability)

    override var hash: Int { nodeID.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SidebarNodeItem else { return false }
        return nodeID == other.nodeID
    }
}
```

**Step 2: Add the file to the Xcode project**

Add `SidebarNodeItem.swift` to the Treemux target in Xcode's project file. If using folder references, just placing it in `Treemux/UI/Sidebar/` should be sufficient.

**Step 3: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```
git add Treemux/UI/Sidebar/SidebarNodeItem.swift
git commit -m "feat: add SidebarNodeItem model for NSOutlineView"
```

---

### Task 3: Create SidebarRowView (custom selection drawing)

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarRowView.swift`

**Step 1: Write SidebarRowView**

Reference: Liney's `SidebarOutlineRowView` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:1210-1227`

```swift
//
//  SidebarRowView.swift
//  Treemux

import AppKit

/// Custom row view that draws an inset rounded-rectangle selection
/// instead of the default full-width highlight.
final class SidebarRowView: NSTableRowView {
    /// Theme colors are injected by the coordinator after creation.
    var selectionFillColor: NSColor = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.26, alpha: 1)
    var selectionStrokeColor: NSColor = NSColor(calibratedRed: 0.25, green: 0.54, blue: 0.87, alpha: 0.9)

    override func drawBackground(in dirtyRect: NSRect) {
        // Intentionally empty — suppress default background
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        selectionFillColor.setFill()
        path.fill()
        selectionStrokeColor.setStroke()
        path.lineWidth = 1.25
        path.stroke()
    }

    // Always show emphasized (blue) selection, never gray
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/SidebarRowView.swift
git commit -m "feat: add SidebarRowView with rounded selection drawing"
```

---

### Task 4: Create SidebarCellView (NSTableCellView + NSHostingView)

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarCellView.swift`

**Step 1: Write SidebarCellView**

Reference: Liney's `SidebarOutlineCellView` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:1229-1249`

```swift
//
//  SidebarCellView.swift
//  Treemux

import AppKit
import SwiftUI

/// Hosts a SwiftUI sidebar row inside an NSTableCellView via NSHostingView.
final class SidebarCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    func apply(content: AnyView) {
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hostingView
        }
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/SidebarCellView.swift
git commit -m "feat: add SidebarCellView for hosting SwiftUI content"
```

---

### Task 5: Create SidebarNodeRow (SwiftUI row content)

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarNodeRow.swift`

**Step 1: Write SidebarNodeRow**

This view dispatches to workspace or worktree content based on the node kind. It reuses `SidebarItemIconView` and adapts the existing `ProjectLabel` / `WorktreeRow` logic but without `@EnvironmentObject` dependencies.

Reference: Liney's `SidebarNodeRow`, `WorkspaceRowContent`, `WorktreeRowContent` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:1251-1404`

```swift
//
//  SidebarNodeRow.swift
//  Treemux

import SwiftUI

/// Dispatches to the appropriate row content based on node kind.
struct SidebarNodeRow: View {
    let node: SidebarNodeItem
    let store: WorkspaceStore
    let theme: ThemeManager

    var body: some View {
        switch node.kind {
        case .workspace(let workspace):
            WorkspaceRowContent(workspace: workspace, store: store, theme: theme)
        case .worktree(let workspace, let worktree):
            WorktreeRowContent(workspace: workspace, worktree: worktree, store: store, theme: theme)
        }
    }
}

/// Workspace row: icon + name + optional branch + optional "current" badge.
private struct WorkspaceRowContent: View {
    @ObservedObject var workspace: WorkspaceModel
    let store: WorkspaceStore
    let theme: ThemeManager
    @State private var isHovering = false

    private var isSelected: Bool {
        store.selectedWorkspaceID == workspace.id
    }

    var body: some View {
        HStack(spacing: 6) {
            SidebarItemIconView(icon: store.sidebarIcon(for: workspace), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if workspace.worktrees.count <= 1, let branch = workspace.currentBranch {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isSelected {
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .background(
            theme.sidebarSelection.opacity(isHovering && !isSelected ? 0.3 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { isHovering = $0 }
    }
}

/// Worktree row: icon + branch name + optional "current" badge.
private struct WorktreeRowContent: View {
    @ObservedObject var workspace: WorkspaceModel
    let worktree: WorktreeModel
    let store: WorkspaceStore
    let theme: ThemeManager
    @State private var isHovering = false

    private var isSelected: Bool {
        store.selectedWorkspaceID == worktree.id
    }

    var body: some View {
        HStack(spacing: 6) {
            SidebarItemIconView(
                icon: store.sidebarIcon(for: worktree, in: workspace),
                size: 18,
                isActive: isSelected
            )
            Text(worktree.branch ?? worktree.path.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            if isSelected {
                Text("current")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .background(
            theme.sidebarSelection.opacity(isHovering && !isSelected ? 0.3 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onHover { isHovering = $0 }
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/SidebarNodeRow.swift
git commit -m "feat: add SidebarNodeRow SwiftUI row content views"
```

---

### Task 6: Create SidebarOutlineView (NSOutlineView subclass)

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarOutlineView.swift`

**Step 1: Write SidebarOutlineView**

Reference: Liney's `SidebarOutlineView` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:1160-1208`

```swift
//
//  SidebarOutlineView.swift
//  Treemux

import AppKit

/// NSOutlineView subclass that forwards keyboard events to closures
/// so the coordinator can handle Enter/Return and Space bar.
final class SidebarOutlineView: NSOutlineView {
    /// Called when user presses Enter/Return on a selected row.
    var activateSelection: (() -> Void)?

    /// Called when user presses Space to toggle expand/collapse.
    var toggleExpansionForSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            activateSelection?()
        case 49: // Space
            toggleExpansionForSelection?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Provide context menu for a specific row.
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }

        // Select the row if not already selected
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        return menuProvider?(row)
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/SidebarOutlineView.swift
git commit -m "feat: add SidebarOutlineView with keyboard and menu support"
```

---

### Task 7: Create SidebarContainerView (NSView layout container)

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarContainerView.swift`

**Step 1: Write SidebarContainerView**

Reference: Liney's `SidebarOutlineContainerView` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:987-1094`

```swift
//
//  SidebarContainerView.swift
//  Treemux

import AppKit
import SwiftUI

/// Container that holds the NSScrollView + NSOutlineView and an optional footer.
final class SidebarContainerView: NSView {
    let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.rowHeight = 36
        outlineView.indentationPerLevel = 12
        outlineView.floatsGroupRows = false
        outlineView.selectionHighlightStyle = .regular
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.intercellSpacing = NSSize(width: 0, height: 4)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        outlineView.draggingDestinationFeedbackStyle = .gap

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadOutlineData() {
        outlineView.reloadData()
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/SidebarContainerView.swift
git commit -m "feat: add SidebarContainerView with scroll and outline layout"
```

---

### Task 8: Create SidebarCoordinator (DataSource + Delegate)

**Files:**
- Create: `Treemux/UI/Sidebar/SidebarCoordinator.swift`

This is the largest and most critical file. It manages data, selection sync, expand/collapse, context menus, and drag-and-drop.

**Step 1: Write SidebarCoordinator**

Reference: Liney's `WorkspaceSidebarCoordinator` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:108-984`

```swift
//
//  SidebarCoordinator.swift
//  Treemux

import AppKit
import SwiftUI

/// NSOutlineView data source and delegate that bridges WorkspaceStore data
/// to the AppKit outline view, handles selection sync, context menus,
/// expand/collapse, and drag-to-reorder.
@MainActor
final class SidebarCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let workspaceDragType = NSPasteboard.PasteboardType("com.treemux.workspace.ids")

    weak var container: SidebarContainerView?
    weak var store: WorkspaceStore?
    weak var theme: ThemeManager?

    /// Action closures set by the NSViewRepresentable to trigger SwiftUI alerts/sheets.
    var requestRename: ((UUID, String) -> Void)?
    var requestDelete: ((UUID) -> Void)?

    private var rootNodes: [SidebarNodeItem] = []
    private var nodeLookup: [String: SidebarNodeItem] = [:]
    private var isApplyingSelection = false
    private var lastDataFingerprint: String = ""

    // MARK: - Attach

    func attach(_ container: SidebarContainerView) {
        self.container = container
        container.outlineView.dataSource = self
        container.outlineView.delegate = self
        container.outlineView.registerForDraggedTypes([Self.workspaceDragType])

        container.outlineView.menuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        container.outlineView.activateSelection = { [weak self] in
            self?.activateSelection()
        }
        container.outlineView.toggleExpansionForSelection = { [weak self] in
            self?.toggleExpansionForSelection()
        }
    }

    // MARK: - Apply (called from updateNSView)

    func apply(
        workspaces: [WorkspaceModel],
        selectedWorkspaceID: UUID?,
        theme: ThemeManager
    ) {
        self.theme = theme
        let fingerprint = dataFingerprint(workspaces: workspaces)
        let dataChanged = fingerprint != lastDataFingerprint

        if dataChanged {
            lastDataFingerprint = fingerprint
            rootNodes = buildNodes(from: workspaces)
            nodeLookup = Dictionary(
                uniqueKeysWithValues: rootNodes.flatMap { $0.flattened() }.map { ($0.nodeID, $0) }
            )
            container?.reloadOutlineData()
            restoreExpansionState()
        }

        synchronizeSelection(selectedWorkspaceID: selectedWorkspaceID)
    }

    // MARK: - Data fingerprint

    private func dataFingerprint(workspaces: [WorkspaceModel]) -> String {
        var parts: [String] = []
        for ws in workspaces {
            parts.append(
                "\(ws.id)|\(ws.name)|\(ws.currentBranch ?? "-")|\(ws.activeWorktreePath ?? "-")" +
                "|\(ws.worktrees.count)|\(ws.workspaceIconOverride?.symbolName ?? "-")"
            )
            for wt in ws.worktrees {
                let icon = ws.iconOverride(for: wt.path)
                parts.append("  \(wt.id)|\(wt.branch ?? "-")|\(icon?.symbolName ?? "-")")
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Build nodes

    private func buildNodes(from workspaces: [WorkspaceModel]) -> [SidebarNodeItem] {
        workspaces.map { workspace in
            let children: [SidebarNodeItem]
            if workspace.worktrees.count > 1 {
                children = workspace.worktrees.map { worktree in
                    SidebarNodeItem(kind: .worktree(workspace, worktree))
                }
            } else {
                children = []
            }
            return SidebarNodeItem(kind: .workspace(workspace), children: children)
        }
    }

    // MARK: - Expansion state

    private func restoreExpansionState() {
        guard let outlineView = container?.outlineView else { return }
        for node in rootNodes where node.isExpandable {
            // Default to expanded
            outlineView.expandItem(node)
        }
    }

    // MARK: - Selection sync

    private func synchronizeSelection(selectedWorkspaceID: UUID?) {
        guard let outlineView = container?.outlineView else { return }
        guard let selectedID = selectedWorkspaceID else {
            if outlineView.selectedRow != -1 {
                isApplyingSelection = true
                outlineView.deselectAll(nil)
                isApplyingSelection = false
            }
            return
        }

        let targetNodeID = selectedID.uuidString
        guard let targetNode = nodeLookup[targetNodeID] else { return }

        let row = outlineView.row(forItem: targetNode)
        guard row >= 0 else { return }

        if !outlineView.selectedRowIndexes.contains(row) {
            isApplyingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isApplyingSelection = false
        }
    }

    // MARK: - Keyboard actions

    private func activateSelection() {
        // Enter/Return on a selected row — no-op for now (selection already triggers detail)
    }

    private func toggleExpansionForSelection() {
        guard let outlineView = container?.outlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarNodeItem else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if item.isExpandable {
            outlineView.expandItem(item)
        }
    }

    // MARK: - Context menu

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let node = container?.outlineView.item(atRow: row) as? SidebarNodeItem,
              let store else { return nil }

        let menu = NSMenu()

        switch node.kind {
        case .workspace(let workspace):
            // Change Icon
            menu.addItem(withTitle: String(localized: "Change Icon…"),
                         action: #selector(changeIconAction(_:)), keyEquivalent: "")
                .representedObject = node
                .target = self

            // Rename (only for repositories)
            if workspace.kind == .repository {
                menu.addItem(withTitle: String(localized: "Rename…"),
                             action: #selector(renameAction(_:)), keyEquivalent: "")
                    .representedObject = node
                    .target = self
            }

            menu.addItem(.separator())

            // Delete
            let deleteItem = menu.addItem(withTitle: String(localized: "Delete"),
                                          action: #selector(deleteAction(_:)), keyEquivalent: "")
            deleteItem.representedObject = node
            deleteItem.target = self

        case .worktree(let workspace, _):
            // Change Icon
            menu.addItem(withTitle: String(localized: "Change Icon…"),
                         action: #selector(changeIconAction(_:)), keyEquivalent: "")
                .representedObject = node
                .target = self
        }

        return menu
    }

    @objc private func changeIconAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNodeItem else { return }
        switch node.kind {
        case .workspace(let ws):
            store?.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                target: .workspace(ws.id)
            )
        case .worktree(let ws, let wt):
            store?.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
                target: .worktree(workspaceID: ws.id, worktreePath: wt.path.path)
            )
        }
    }

    @objc private func renameAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNodeItem,
              case .workspace(let ws) = node.kind else { return }
        requestRename?(ws.id, ws.name)
    }

    @objc private func deleteAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNodeItem,
              case .workspace(let ws) = node.kind else { return }
        requestDelete?(ws.id)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNodeItem else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNodeItem else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNodeItem else { return false }
        return node.isExpandable
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNodeItem,
              let store, let theme else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = outlineView.makeView(withIdentifier: cellID, owner: nil) as? SidebarCellView
            ?? SidebarCellView()
        cell.identifier = cellID
        cell.apply(content: AnyView(SidebarNodeRow(node: node, store: store, theme: theme)))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarRowView()
        if let theme {
            rowView.selectionFillColor = theme.sidebarSelectionFillNS
            rowView.selectionStrokeColor = theme.sidebarSelectionStrokeNS
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNodeItem else { return 36 }
        switch node.kind {
        case .workspace: return 36
        case .worktree: return 28
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection,
              let outlineView = notification.object as? NSOutlineView,
              let store else { return }

        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNodeItem else { return }

        switch node.kind {
        case .workspace(let workspace):
            store.selectWorkspace(workspace.id)
        case .worktree(_, let worktree):
            store.selectedWorkspaceID = worktree.id
        }
    }

    // MARK: - Drag and Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? SidebarNodeItem,
              case .workspace = node.kind else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(node.nodeID, forType: Self.workspaceDragType)
        return pbItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Only allow drops at root level (reorder workspaces)
        guard item == nil, index >= 0 else { return [] }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard item == nil else { return false }
        let pasteboard = info.draggingPasteboard
        guard let items = pasteboard.pasteboardItems else { return false }
        let ids = items.compactMap { $0.string(forType: Self.workspaceDragType) }
            .compactMap { UUID(uuidString: $0) }
        guard !ids.isEmpty else { return false }

        // Translate to IndexSet-based move for compatibility with existing store method
        guard let store else { return false }
        let localWorkspaces = store.localWorkspaces
        let sourceIndices = IndexSet(ids.compactMap { id in
            localWorkspaces.firstIndex { $0.id == id }
        })
        guard !sourceIndices.isEmpty else { return false }
        store.moveLocalWorkspace(from: sourceIndices, to: min(index, localWorkspaces.count))
        return true
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED (or minor compile issues to fix — the context menu NSMenuItem chaining may need adjustment for Swift syntax)

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/SidebarCoordinator.swift
git commit -m "feat: add SidebarCoordinator with data source, delegate, and interactions"
```

---

### Task 9: Create WorkspaceOutlineSidebar (NSViewRepresentable)

**Files:**
- Create: `Treemux/UI/Sidebar/WorkspaceOutlineSidebar.swift`

**Step 1: Write WorkspaceOutlineSidebar**

Reference: Liney's `WorkspaceOutlineSidebar` at `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Sidebar/WorkspaceSidebarView.swift:53-78`

```swift
//
//  WorkspaceOutlineSidebar.swift
//  Treemux

import SwiftUI

/// NSViewRepresentable that bridges WorkspaceStore to the AppKit NSOutlineView sidebar.
struct WorkspaceOutlineSidebar: NSViewRepresentable {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var theme: ThemeManager

    /// Closures to trigger SwiftUI alerts in the parent view.
    var onRequestRename: (UUID, String) -> Void
    var onRequestDelete: (UUID) -> Void

    func makeCoordinator() -> SidebarCoordinator {
        SidebarCoordinator()
    }

    func makeNSView(context: Context) -> SidebarContainerView {
        let container = SidebarContainerView()
        context.coordinator.store = store
        context.coordinator.theme = theme
        context.coordinator.requestRename = onRequestRename
        context.coordinator.requestDelete = onRequestDelete
        context.coordinator.attach(container)
        return container
    }

    func updateNSView(_ nsView: SidebarContainerView, context: Context) {
        context.coordinator.store = store
        context.coordinator.theme = theme
        context.coordinator.requestRename = onRequestRename
        context.coordinator.requestDelete = onRequestDelete
        context.coordinator.apply(
            workspaces: store.localWorkspaces + store.remoteWorkspaceGroups.flatMap(\.targets),
            selectedWorkspaceID: store.selectedWorkspaceID,
            theme: theme
        )
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
git add Treemux/UI/Sidebar/WorkspaceOutlineSidebar.swift
git commit -m "feat: add WorkspaceOutlineSidebar NSViewRepresentable bridge"
```

---

### Task 10: Rewrite WorkspaceSidebarView to use the new outline

**Files:**
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`

**Step 1: Rewrite the body**

Replace the entire `List(selection:)` block and remove the deleted types (`OutlineViewConfigurator`, `sidebarRowBackground`, `WorkspaceRowGroup`, `ProjectLabel`, `WorktreeRow`). Keep the outer shell with alerts/sheets.

The new `WorkspaceSidebarView.body`:

```swift
struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager

    // Rename dialog state
    @State private var renamingWorkspaceID: UUID?
    @State private var renameText: String = ""

    // Delete confirmation state
    @State private var deletingWorkspaceID: UUID?

    // Open project sheet state
    @State private var showOpenProjectSheet = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceOutlineSidebar(
                store: store,
                theme: theme,
                onRequestRename: { id, name in
                    renameText = name
                    renamingWorkspaceID = id
                },
                onRequestDelete: { id in
                    deletingWorkspaceID = id
                }
            )

            // Bottom bar with "Open Project" button
            Divider()
            Button {
                showOpenProjectSheet = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                    Text(String(localized: "Open Project..."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .background(theme.sidebarBackground)
        // Rename alert
        .alert(String(localized: "Rename Project"), isPresented: Binding(
            get: { renamingWorkspaceID != nil },
            set: { if !$0 { renamingWorkspaceID = nil } }
        )) {
            TextField(String(localized: "Project Name"), text: $renameText)
            Button(String(localized: "Cancel"), role: .cancel) {
                renamingWorkspaceID = nil
            }
            Button(String(localized: "Rename")) {
                if let id = renamingWorkspaceID {
                    store.renameWorkspace(id, to: renameText)
                }
                renamingWorkspaceID = nil
            }
        }
        // Delete confirmation alert
        .alert(String(localized: "Delete Project?"), isPresented: Binding(
            get: { deletingWorkspaceID != nil },
            set: { if !$0 { deletingWorkspaceID = nil } }
        )) {
            Button(String(localized: "Cancel"), role: .cancel) {
                deletingWorkspaceID = nil
            }
            Button(String(localized: "Delete"), role: .destructive) {
                if let id = deletingWorkspaceID {
                    store.removeWorkspace(id)
                }
                deletingWorkspaceID = nil
            }
        } message: {
            Text(String(localized: "This will remove the project from the sidebar. Files on disk will not be affected."))
        }
        .sheet(isPresented: $showOpenProjectSheet) {
            OpenProjectSheet()
        }
        .sheet(item: $store.sidebarIconCustomizationRequest) { request in
            SidebarIconCustomizationSheet(request: request)
                .environmentObject(store)
                .environmentObject(theme)
        }
    }
}
```

**Step 2: Remove deleted code**

Delete these from `WorkspaceSidebarView.swift`:
- `OutlineViewConfigurator` struct (lines 192-226)
- `sidebarRowBackground()` function (lines 228-244)
- `WorkspaceRowGroup` struct (lines 246-314)
- `ProjectLabel` struct (lines 316-341)
- `WorktreeRow` struct (lines 343-395)
- `remoteGroupLabel()` method (no longer needed — remote grouping will be addressed separately)
- `hoveredID` state property (no longer needed)

**Step 3: Build and verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED. If there are compile errors from other files referencing deleted types (e.g., `ProjectLabel`, `WorktreeRow`), grep for usages and remove them.

**Step 4: Commit**

```
git add Treemux/UI/Sidebar/WorkspaceSidebarView.swift
git commit -m "feat: rewrite WorkspaceSidebarView to use NSOutlineView sidebar"
```

---

### Task 11: Build, run, and fix integration issues

**Step 1: Full build**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | grep -E '(error:|BUILD)'`

Fix any compile errors. Common issues to watch for:
- Missing Xcode project references for new files
- `@MainActor` annotation requirements on NSOutlineView delegate methods
- NSMenuItem property chaining syntax in context menu builder
- Any remaining references to deleted types (`WorkspaceRowGroup`, `ProjectLabel`, `WorktreeRow`, `sidebarRowBackground`)

**Step 2: Run the app and verify**

```
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<hash>/Build/Products/Debug/Treemux.app
```

Verify:
- [ ] Sidebar displays all workspaces
- [ ] Clicking a workspace selects it with rounded highlight
- [ ] Clicking a worktree selects it and switches the detail view
- [ ] Selection highlight is inset with rounded corners (not full width)
- [ ] No lag when clicking between items
- [ ] Expand/collapse disclosure triangles work for multi-worktree projects
- [ ] Right-click context menu shows Change Icon / Rename / Delete
- [ ] Drag-to-reorder works for workspace rows
- [ ] Hover shows subtle background highlight
- [ ] "Open Project..." button at bottom works
- [ ] Rename and Delete alerts work correctly

**Step 3: Fix any issues found during testing**

Iterate on visual polish: adjust `dx`/`dy` insets, corner radius, colors, row heights until the selection UI matches the Liney feel.

**Step 4: Commit**

```
git add -A
git commit -m "fix: resolve integration issues in NSOutlineView sidebar migration"
```
