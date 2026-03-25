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

struct PaneLeaf: Codable, Equatable, Hashable {
    let paneID: UUID
}

// MARK: - Split node

struct PaneSplitNode: Codable, Equatable, Hashable {
    var id: UUID
    var axis: SplitAxis
    var fraction: Double
    var first: SessionLayoutNode
    var second: SessionLayoutNode

    static let minimumFraction: Double = 0.12
    static let maximumFraction: Double = 0.88

    init(
        id: UUID = UUID(),
        axis: SplitAxis,
        fraction: Double = 0.5,
        first: SessionLayoutNode,
        second: SessionLayoutNode
    ) {
        self.id = id
        self.axis = axis
        self.fraction = fraction
        self.first = first
        self.second = second
    }

    var clampedFraction: Double {
        min(max(fraction, Self.minimumFraction), Self.maximumFraction)
    }
}

// MARK: - Layout tree

indirect enum SessionLayoutNode: Codable, Equatable, Hashable {
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

    /// Returns the first pane ID in traversal order.
    var firstPaneID: UUID? {
        switch self {
        case .pane(let leaf):
            return leaf.paneID
        case .split(let split):
            return split.first.firstPaneID ?? split.second.firstPaneID
        }
    }

    /// Returns the last pane ID in traversal order.
    var lastPaneID: UUID? {
        switch self {
        case .pane(let leaf):
            return leaf.paneID
        case .split(let split):
            return split.second.lastPaneID ?? split.first.lastPaneID
        }
    }

    /// Splits the pane with the given ID, inserting a new pane along the specified axis.
    mutating func split(
        paneID: UUID,
        axis: SplitAxis,
        newPaneID: UUID,
        fraction: Double = 0.5,
        placement: PaneSplitPlacement = .after
    ) -> Bool {
        switch self {
        case .pane(let leaf):
            guard leaf.paneID == paneID else { return false }
            let existing = SessionLayoutNode.pane(PaneLeaf(paneID: paneID))
            let inserted = SessionLayoutNode.pane(PaneLeaf(paneID: newPaneID))
            self = .split(
                PaneSplitNode(
                    axis: axis,
                    fraction: fraction,
                    first: placement == .before ? inserted : existing,
                    second: placement == .before ? existing : inserted
                )
            )
            return true
        case .split(var splitNode):
            if splitNode.first.split(
                paneID: paneID,
                axis: axis,
                newPaneID: newPaneID,
                fraction: fraction,
                placement: placement
            ) {
                self = .split(splitNode)
                return true
            }
            if splitNode.second.split(
                paneID: paneID,
                axis: axis,
                newPaneID: newPaneID,
                fraction: fraction,
                placement: placement
            ) {
                self = .split(splitNode)
                return true
            }
            return false
        }
    }

    /// Updates the fraction of the split node with the given ID.
    mutating func updateFraction(splitID: UUID, fraction: Double) -> Bool {
        switch self {
        case .pane:
            return false
        case .split(var splitNode):
            if splitNode.id == splitID {
                splitNode.fraction = min(max(fraction, PaneSplitNode.minimumFraction), PaneSplitNode.maximumFraction)
                self = .split(splitNode)
                return true
            }
            if splitNode.first.updateFraction(splitID: splitID, fraction: fraction) {
                self = .split(splitNode)
                return true
            }
            if splitNode.second.updateFraction(splitID: splitID, fraction: fraction) {
                self = .split(splitNode)
                return true
            }
            return false
        }
    }

    /// Removes the pane with the given ID, collapsing the parent split.
    mutating func removePane(_ id: UUID) {
        guard let updated = removingPane(id) else { return }
        self = updated
    }

    /// Equalizes all split fractions to 0.5.
    mutating func equalizeSplits() {
        switch self {
        case .pane:
            return
        case .split(var splitNode):
            splitNode.fraction = 0.5
            splitNode.first.equalizeSplits()
            splitNode.second.equalizeSplits()
            self = .split(splitNode)
        }
    }

    /// Resizes the nearest split containing the pane in the given direction.
    mutating func resizeSplit(containing paneID: UUID, toward direction: PaneFocusDirection, amount: UInt16) -> Bool {
        let axis: SplitAxis = switch direction {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
        guard let splitID = nearestSplitID(containing: paneID, axis: axis) else { return false }
        let rawDelta = max(Double(amount), 1) / 320
        let delta = min(max(rawDelta, 0.02), 0.16)
        switch direction {
        case .left, .up:
            return adjustFraction(splitID: splitID, delta: -delta)
        case .right, .down:
            return adjustFraction(splitID: splitID, delta: delta)
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

    /// Navigate to the pane in a specific direction (left/right/up/down).
    func paneID(in direction: PaneFocusDirection, from paneID: UUID) -> UUID? {
        guard let path = pathToPane(paneID) else { return nil }
        for step in path.reversed() {
            switch direction {
            case .left:
                if step.axis == .horizontal, step.side == .second {
                    return step.sibling.lastPaneID
                }
            case .right:
                if step.axis == .horizontal, step.side == .first {
                    return step.sibling.firstPaneID
                }
            case .up:
                if step.axis == .vertical, step.side == .second {
                    return step.sibling.lastPaneID
                }
            case .down:
                if step.axis == .vertical, step.side == .first {
                    return step.sibling.firstPaneID
                }
            }
        }
        return nil
    }

    // MARK: - Private helpers

    private func removingPane(_ paneID: UUID) -> SessionLayoutNode? {
        switch self {
        case .pane(let leaf):
            return leaf.paneID == paneID ? nil : self
        case .split(let split):
            let first = split.first.removingPane(paneID)
            let second = split.second.removingPane(paneID)

            switch (first, second) {
            case (nil, nil):
                return nil
            case (.some(let remaining), nil):
                return remaining
            case (nil, .some(let remaining)):
                return remaining
            case (.some(let firstNode), .some(let secondNode)):
                return .split(
                    PaneSplitNode(
                        id: split.id,
                        axis: split.axis,
                        fraction: split.fraction,
                        first: firstNode,
                        second: secondNode
                    )
                )
            }
        }
    }

    private enum PathSide {
        case first
        case second
    }

    private struct PathStep {
        var splitID: UUID
        var axis: SplitAxis
        var side: PathSide
        var sibling: SessionLayoutNode
    }

    private func pathToPane(_ paneID: UUID) -> [PathStep]? {
        switch self {
        case .pane(let leaf):
            return leaf.paneID == paneID ? [] : nil
        case .split(let split):
            if let nested = split.first.pathToPane(paneID) {
                return [PathStep(splitID: split.id, axis: split.axis, side: .first, sibling: split.second)] + nested
            }
            if let nested = split.second.pathToPane(paneID) {
                return [PathStep(splitID: split.id, axis: split.axis, side: .second, sibling: split.first)] + nested
            }
            return nil
        }
    }

    private mutating func adjustFraction(splitID: UUID, delta: Double) -> Bool {
        switch self {
        case .pane:
            return false
        case .split(var splitNode):
            if splitNode.id == splitID {
                splitNode.fraction = min(max(splitNode.fraction + delta, PaneSplitNode.minimumFraction), PaneSplitNode.maximumFraction)
                self = .split(splitNode)
                return true
            }
            if splitNode.first.adjustFraction(splitID: splitID, delta: delta) {
                self = .split(splitNode)
                return true
            }
            if splitNode.second.adjustFraction(splitID: splitID, delta: delta) {
                self = .split(splitNode)
                return true
            }
            return false
        }
    }

    private func nearestSplitID(containing paneID: UUID, axis: SplitAxis) -> UUID? {
        pathToPane(paneID)?
            .reversed()
            .first(where: { $0.axis == axis })?
            .splitID
    }
}

// MARK: - Direction

enum SplitDirection {
    case next
    case previous
}
