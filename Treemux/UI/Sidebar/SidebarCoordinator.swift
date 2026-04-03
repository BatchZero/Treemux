//
//  SidebarCoordinator.swift
//  Treemux

import AppKit
import SwiftUI

/// Coordinator that serves as NSOutlineView data source and delegate,
/// bridging the AppKit sidebar with the SwiftUI WorkspaceStore.
@MainActor
final class SidebarCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

    private static let workspaceDragType = NSPasteboard.PasteboardType("com.treemux.workspace.ids")

    weak var container: SidebarContainerView?
    weak var store: WorkspaceStore?
    var theme: ThemeManager?

    // Closures called from context menu to trigger SwiftUI alerts.
    var requestRename: ((UUID, String) -> Void)?
    var requestDelete: ((UUID) -> Void)?

    private var rootNodes: [SidebarNodeItem] = []
    private var isApplyingSelection = false
    private var lastDataFingerprint: String = ""

    // MARK: - Attach

    /// Wires the coordinator as data source and delegate on the container's outline view.
    func attach(_ container: SidebarContainerView) {
        self.container = container
        let outlineView = container.outlineView
        outlineView.dataSource = self
        outlineView.delegate = self

        outlineView.registerForDraggedTypes([Self.workspaceDragType])

        outlineView.menuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        outlineView.activateSelection = { [weak self] in
            self?.activateSelection()
        }
        outlineView.toggleExpansionForSelection = { [weak self] in
            self?.toggleExpansionForSelection()
        }
    }

    // MARK: - Apply (Diff + Rebuild)

    /// Called from updateNSView. Rebuilds nodes only when the fingerprint changes;
    /// always synchronizes selection.
    func apply(
        store: WorkspaceStore,
        selectedWorkspaceID: UUID?,
        theme: ThemeManager
    ) {
        self.theme = theme
        let localWorkspaces = store.localWorkspaces
        let remoteGroups = store.remoteWorkspaceGroups
        let allWorkspaces = localWorkspaces + remoteGroups.flatMap(\.targets)
        let fingerprint = dataFingerprint(workspaces: allWorkspaces)
        let dataChanged = fingerprint != lastDataFingerprint

        if dataChanged {
            lastDataFingerprint = fingerprint
            rootNodes = buildNodes(
                localWorkspaces: localWorkspaces,
                remoteGroups: remoteGroups
            )
            container?.reloadOutlineData()

            guard let outlineView = container?.outlineView else { return }
            // Expand all nodes by default, then collapse persisted sections.
            for node in rootNodes {
                outlineView.expandItem(node)
                // Expand workspace children (worktrees)
                for child in node.children {
                    if child.isExpandable {
                        outlineView.expandItem(child)
                    }
                }
            }
            // Apply persisted collapsed state
            for node in rootNodes {
                if case .section(let section) = node.kind,
                   store.collapsedSections.contains(section.persistenceKey) {
                    outlineView.collapseItem(node)
                }
            }
            synchronizeSelection(on: outlineView, selectedWorkspaceID: selectedWorkspaceID)
        } else {
            guard let outlineView = container?.outlineView else { return }
            synchronizeSelection(on: outlineView, selectedWorkspaceID: selectedWorkspaceID)
        }
    }

    // MARK: - Fingerprint

    private func dataFingerprint(workspaces: [WorkspaceModel]) -> String {
        var parts: [String] = []
        for ws in workspaces {
            let iconKey = ws.workspaceIcon.map { "\($0)" } ?? "-"
            parts.append("\(ws.id)|\(ws.name)|\(ws.currentBranch ?? "-")|\(ws.activeWorktreePath)|\(ws.worktrees.count)|\(iconKey)")
            for wt in ws.worktrees {
                let wtIcon = ws.worktreeIconOverrides[wt.path.path].map { "\($0)" } ?? "-"
                parts.append("  \(wt.id)|\(wt.path.path)|\(wt.branch ?? "-")|\(wtIcon)")
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Build Nodes

    private func buildNodes(
        localWorkspaces: [WorkspaceModel],
        remoteGroups: [(key: String, targets: [WorkspaceModel])]
    ) -> [SidebarNodeItem] {
        let hasRemote = !remoteGroups.isEmpty

        if !hasRemote {
            // No sections — flat list like before
            return localWorkspaces.map { makeWorkspaceNode($0) }
        }

        // Build sectioned tree
        var sections: [SidebarNodeItem] = []

        // Local section
        if !localWorkspaces.isEmpty {
            let localChildren = localWorkspaces.map { makeWorkspaceNode($0) }
            sections.append(SidebarNodeItem(
                kind: .section(.local),
                children: localChildren
            ))
        }

        // Remote sections
        for group in remoteGroups {
            let displayTitle: String
            if let firstTarget = group.targets.first?.sshTarget {
                displayTitle = WorkspaceStore.remoteGroupDisplayTitle(for: firstTarget)
            } else {
                displayTitle = group.key
            }
            let remoteChildren = group.targets.map { makeWorkspaceNode($0) }
            sections.append(SidebarNodeItem(
                kind: .section(.remote(groupKey: group.key, displayTitle: displayTitle)),
                children: remoteChildren
            ))
        }

        return sections
    }

    private func makeWorkspaceNode(_ workspace: WorkspaceModel) -> SidebarNodeItem {
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

    // MARK: - Selection Sync

    private func synchronizeSelection(
        on outlineView: NSOutlineView,
        selectedWorkspaceID: UUID?
    ) {
        guard let selectedID = selectedWorkspaceID else {
            isApplyingSelection = true
            outlineView.deselectAll(nil)
            isApplyingSelection = false
            return
        }

        // Find the node matching the selected ID (could be workspace or worktree).
        let allNodes = rootNodes.flatMap { $0.flattened() }
        guard let targetNode = allNodes.first(where: { $0.nodeID == selectedID.uuidString }) else {
            return
        }

        let row = outlineView.row(forItem: targetNode)
        guard row >= 0 else { return }

        // Only update if it differs from current selection.
        if outlineView.selectedRow != row {
            isApplyingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            isApplyingSelection = false
        }

        // Refresh visible rows so isSelected is up-to-date in cell content.
        refreshVisibleRows(on: outlineView)
    }

    /// Re-applies cell content for all visible rows so selection state is reflected.
    private func refreshVisibleRows(on outlineView: NSOutlineView) {
        let visibleRange = outlineView.rows(in: outlineView.visibleRect)
        for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            guard let node = outlineView.item(atRow: row) as? SidebarNodeItem,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else {
                continue
            }
            let isSelected = outlineView.selectedRowIndexes.contains(row)
            let content = makeCellContent(for: node, isSelected: isSelected)
            cell.apply(content: content)
        }
    }

    // MARK: - Cell Content

    private func makeCellContent(for node: SidebarNodeItem, isSelected: Bool) -> AnyView {
        guard let store, let theme else {
            return AnyView(EmptyView())
        }
        return AnyView(
            SidebarNodeRow(
                node: node,
                store: store,
                theme: theme,
                isSelected: isSelected
            )
        )
    }

    // MARK: - Keyboard

    private func activateSelection() {
        guard let outlineView = container?.outlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNodeItem else { return }

        switch node.kind {
        case .section:
            break
        case .workspace(let ws):
            store?.selectWorkspace(ws.id)
        case .worktree(_, let wt):
            store?.selectWorkspace(wt.id)
        }
    }

    private func toggleExpansionForSelection() {
        guard let outlineView = container?.outlineView else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNodeItem,
              node.isExpandable else { return }

        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    // MARK: - Context Menu

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let outlineView = container?.outlineView,
              row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNodeItem else { return nil }

        let menu = NSMenu()

        switch node.kind {
        case .section:
            return nil

        case .workspace(let ws):
            // Change Icon
            let iconItem = NSMenuItem(
                title: String(localized: "Change Icon…"),
                action: #selector(changeWorkspaceIcon(_:)),
                keyEquivalent: ""
            )
            iconItem.target = self
            iconItem.representedObject = ws.id
            menu.addItem(iconItem)

            // Rename (only for repositories)
            if ws.kind == .repository {
                let renameItem = NSMenuItem(
                    title: String(localized: "Rename…"),
                    action: #selector(renameWorkspace(_:)),
                    keyEquivalent: ""
                )
                renameItem.target = self
                renameItem.representedObject = ["id": ws.id, "name": ws.name] as [String: Any]
                menu.addItem(renameItem)
            }

            menu.addItem(.separator())

            // Delete
            let deleteItem = NSMenuItem(
                title: String(localized: "Delete"),
                action: #selector(deleteWorkspace(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = self
            deleteItem.representedObject = ws.id
            menu.addItem(deleteItem)

        case .worktree(let ws, let wt):
            // Change Icon for worktree
            let iconItem = NSMenuItem(
                title: String(localized: "Change Icon…"),
                action: #selector(changeWorktreeIcon(_:)),
                keyEquivalent: ""
            )
            iconItem.target = self
            iconItem.representedObject = ["workspaceID": ws.id, "worktreePath": wt.path.path] as [String: Any]
            menu.addItem(iconItem)
        }

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func changeWorkspaceIcon(_ sender: NSMenuItem) {
        guard let wsID = sender.representedObject as? UUID else { return }
        store?.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
            target: .workspace(wsID)
        )
    }

    @objc private func renameWorkspace(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let id = dict["id"] as? UUID,
              let name = dict["name"] as? String else { return }
        requestRename?(id, name)
    }

    @objc private func deleteWorkspace(_ sender: NSMenuItem) {
        guard let wsID = sender.representedObject as? UUID else { return }
        requestDelete?(wsID)
    }

    @objc private func changeWorktreeIcon(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let workspaceID = dict["workspaceID"] as? UUID,
              let worktreePath = dict["worktreePath"] as? String else { return }
        store?.sidebarIconCustomizationRequest = SidebarIconCustomizationRequest(
            target: .worktree(workspaceID: workspaceID, worktreePath: worktreePath)
        )
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNodeItem)?.children.count ?? rootNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let nodes = (item as? SidebarNodeItem)?.children ?? rootNodes
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNodeItem)?.isExpandable ?? false
    }

    // MARK: - Drag & Drop (NSOutlineViewDataSource)

    private func findSection(forWorkspaceID id: UUID) -> SidebarSection? {
        for node in rootNodes {
            if case .section(let section) = node.kind {
                if node.children.contains(where: {
                    if case .workspace(let ws) = $0.kind { return ws.id == id }
                    return false
                }) {
                    return section
                }
            }
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNodeItem,
              case .workspace(let ws) = node.kind else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(ws.id.uuidString, forType: Self.workspaceDragType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let payload = info.draggingPasteboard.string(forType: Self.workspaceDragType),
              let draggedID = UUID(uuidString: payload) else { return [] }

        let hasSections = rootNodes.contains { if case .section = $0.kind { return true }; return false }

        // When an expanded workspace is proposed as the drop target,
        // retarget the drop to its parent (section or root level).
        if let targetNode = item as? SidebarNodeItem, case .workspace = targetNode.kind {
            if hasSections {
                for sectionNode in rootNodes {
                    if let wsIndex = sectionNode.children.firstIndex(where: { $0 === targetNode }) {
                        let retargetIndex = index <= 0 ? wsIndex : wsIndex + 1
                        outlineView.setDropItem(sectionNode, dropChildIndex: retargetIndex)
                        if case .section(let targetSection) = sectionNode.kind {
                            guard let sourceSection = findSection(forWorkspaceID: draggedID) else { return [] }
                            return sourceSection.persistenceKey == targetSection.persistenceKey ? .move : []
                        }
                    }
                }
                return []
            } else {
                if let wsIndex = rootNodes.firstIndex(where: { $0 === targetNode }) {
                    let retargetIndex = index <= 0 ? wsIndex : wsIndex + 1
                    outlineView.setDropItem(nil, dropChildIndex: retargetIndex)
                    return .move
                }
                return []
            }
        }

        if hasSections {
            // Must drop into a section node
            guard let targetNode = item as? SidebarNodeItem,
                  case .section(let targetSection) = targetNode.kind else { return [] }

            // Find which section the dragged workspace belongs to
            guard let sourceSection = findSection(forWorkspaceID: draggedID) else { return [] }

            // Only allow drop within the same section
            return sourceSection.persistenceKey == targetSection.persistenceKey ? .move : []
        } else {
            // No sections — flat mode, drop at root level only
            guard item == nil else { return [] }
            return .move
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let payload = info.draggingPasteboard.string(forType: Self.workspaceDragType),
              let draggedID = UUID(uuidString: payload) else { return false }

        let hasSections = rootNodes.contains { if case .section = $0.kind { return true }; return false }

        if hasSections {
            guard let sectionNode = item as? SidebarNodeItem,
                  case .section(let section) = sectionNode.kind else { return false }

            let children = sectionNode.children
            guard let sourceIndex = children.firstIndex(where: {
                if case .workspace(let ws) = $0.kind { return ws.id == draggedID }
                return false
            }) else { return false }

            let destination = index == -1 ? children.count : index

            switch section {
            case .local:
                store?.moveLocalWorkspace(from: IndexSet(integer: sourceIndex), to: destination)
            case .remote(let groupKey, _):
                store?.moveRemoteWorkspace(groupKey: groupKey, from: IndexSet(integer: sourceIndex), to: destination)
            }
            return true
        } else {
            // Flat mode — local only
            guard item == nil else { return false }
            guard let sourceIndex = rootNodes.firstIndex(where: {
                if case .workspace(let ws) = $0.kind { return ws.id == draggedID }
                return false
            }) else { return false }

            let destination = index == -1 ? rootNodes.count : index
            store?.moveLocalWorkspace(from: IndexSet(integer: sourceIndex), to: destination)
            return true
        }
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNodeItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView()
        cell.identifier = identifier

        let row = outlineView.row(forItem: node)
        let isSelected = row >= 0 && outlineView.selectedRowIndexes.contains(row)
        cell.apply(content: makeCellContent(for: node, isSelected: isSelected))
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
        case .section: return 24
        case .workspace: return 36
        case .worktree: return 28
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNodeItem else { return false }
        switch node.kind {
        case .section: return false
        case .workspace, .worktree: return true
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNodeItem,
              case .section(let section) = node.kind else { return }
        store?.collapsedSections.insert(section.persistenceKey)
        store?.saveWorkspaceState()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNodeItem,
              case .section(let section) = node.kind else { return }
        store?.collapsedSections.remove(section.persistenceKey)
        store?.saveWorkspaceState()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection,
              let outlineView = notification.object as? NSOutlineView else { return }

        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNodeItem else { return }

        // Refresh visible cells to update isSelected state.
        refreshVisibleRows(on: outlineView)

        switch node.kind {
        case .section:
            break
        case .workspace(let ws):
            store?.selectWorkspace(ws.id)
        case .worktree(_, let wt):
            store?.selectWorkspace(wt.id)
        }
    }
}
