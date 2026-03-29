//
//  SidebarNodeItem.swift
//  Treemux

import Foundation

/// Tree node used by the AppKit NSOutlineView sidebar.
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

    func flattened() -> [SidebarNodeItem] {
        [self] + children.flatMap { $0.flattened() }
    }

    override var hash: Int { nodeID.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SidebarNodeItem else { return false }
        return nodeID == other.nodeID
    }
}
