//
//  PaneLayout.swift
//  Treemux
//

import Foundation

// MARK: - Split axis

enum SplitAxis: String, Codable {
    case horizontal
    case vertical
}

// MARK: - Pane leaf

struct PaneLeaf: Codable, Equatable {
    let paneID: UUID
}

// MARK: - Split node

struct PaneSplitNode: Codable {
    var axis: SplitAxis
    var fraction: Double
    var first: SessionLayoutNode
    var second: SessionLayoutNode

    static let minimumFraction: Double = 0.12
    static let maximumFraction: Double = 0.88

    var clampedFraction: Double {
        min(max(fraction, Self.minimumFraction), Self.maximumFraction)
    }
}

// MARK: - Layout tree

indirect enum SessionLayoutNode: Codable {
    case pane(PaneLeaf)
    case split(PaneSplitNode)

    /// Returns all pane IDs in left-to-right / top-to-bottom order.
    var paneIDs: [UUID] {
        switch self {
        case .pane(let leaf):
            return [leaf.paneID]
        case .split(let node):
            return node.first.paneIDs + node.second.paneIDs
        }
    }

    /// Removes the pane with the given ID, collapsing the parent split.
    mutating func removePane(_ id: UUID) {
        switch self {
        case .pane:
            return
        case .split(let node):
            // If the target is a direct child, collapse to the sibling.
            if case .pane(let leaf) = node.first, leaf.paneID == id {
                self = node.second
                return
            }
            if case .pane(let leaf) = node.second, leaf.paneID == id {
                self = node.first
                return
            }
            // Otherwise recurse into children.
            var mutableNode = node
            mutableNode.first.removePane(id)
            mutableNode.second.removePane(id)
            self = .split(mutableNode)
        }
    }

    /// Navigate to the next or previous pane from the current pane.
    func paneID(in direction: SplitDirection, from currentID: UUID) -> UUID? {
        let ids = paneIDs
        guard let index = ids.firstIndex(of: currentID) else { return nil }
        switch direction {
        case .next:
            let nextIndex = (index + 1) % ids.count
            return ids[nextIndex]
        case .previous:
            let prevIndex = (index - 1 + ids.count) % ids.count
            return ids[prevIndex]
        }
    }
}

// MARK: - Direction

enum SplitDirection {
    case next
    case previous
}
