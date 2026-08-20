import AppKit
import XCTest
@testable import Treemux

final class PaneLayoutTests: XCTestCase {

    @MainActor
    func testOlderTerminalContainerCannotReclaimViewAfterTransfer() {
        let terminalView = NSView()
        let olderContainer = TerminalViewContainer()
        let newerContainer = TerminalViewContainer()

        olderContainer.attach(terminalView, restoreFocus: false)
        newerContainer.attach(terminalView, restoreFocus: false)
        olderContainer.attach(terminalView, restoreFocus: false)

        XCTAssertTrue(terminalView.superview === newerContainer)
    }

    func testSinglePaneLayout() throws {
        let paneID = UUID()
        let layout = SessionLayoutNode.pane(PaneLeaf(paneID: paneID))
        XCTAssertEqual(layout.paneIDs, [paneID])
    }

    func testSplitLayoutContainsBothPanes() throws {
        let left = UUID()
        let right = UUID()
        let layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .horizontal,
            fraction: 0.5,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))
        XCTAssertEqual(Set(layout.paneIDs), Set([left, right]))
    }

    func testLayoutCodableRoundTrip() throws {
        let left = UUID()
        let right = UUID()
        let layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .vertical,
            fraction: 0.3,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(SessionLayoutNode.self, from: data)
        XCTAssertEqual(decoded.paneIDs.count, 2)
        XCTAssertTrue(decoded.paneIDs.contains(left))
        XCTAssertTrue(decoded.paneIDs.contains(right))
    }

    func testRemovePaneFromSplit() throws {
        let left = UUID()
        let right = UUID()
        var layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .horizontal,
            fraction: 0.5,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))
        layout.removePane(left)
        XCTAssertEqual(layout.paneIDs, [right])
    }

    func testCenterDropSwapsPanePositionsWithoutChangingSplit() throws {
        let left = UUID()
        let right = UUID()
        let splitID = UUID()
        var layout = SessionLayoutNode.split(PaneSplitNode(
            id: splitID,
            axis: .horizontal,
            fraction: 0.35,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))

        XCTAssertTrue(layout.rearrangePane(left, relativeTo: right, dropZone: .center))
        XCTAssertEqual(layout.paneIDs, [right, left])
        guard case .split(let split) = layout else {
            return XCTFail("expected split layout")
        }
        XCTAssertEqual(split.id, splitID)
        XCTAssertEqual(split.axis, .horizontal)
        XCTAssertEqual(split.fraction, 0.35, accuracy: 0.001)
    }

    func testEdgeDropRemovesSourceThenSplitsTargetOnRequestedSide() throws {
        let paneA = UUID()
        let paneB = UUID()
        let paneC = UUID()
        var layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .horizontal,
            first: .pane(PaneLeaf(paneID: paneA)),
            second: .split(PaneSplitNode(
                axis: .vertical,
                first: .pane(PaneLeaf(paneID: paneB)),
                second: .pane(PaneLeaf(paneID: paneC))
            ))
        ))

        XCTAssertTrue(layout.rearrangePane(paneC, relativeTo: paneA, dropZone: .left))
        XCTAssertEqual(layout.paneIDs, [paneC, paneA, paneB])
        guard case .split(let root) = layout,
              case .split(let movedSplit) = root.first else {
            return XCTFail("expected source to split the target leaf")
        }
        XCTAssertEqual(root.axis, .horizontal)
        XCTAssertEqual(movedSplit.axis, .horizontal)
        XCTAssertEqual(movedSplit.first.paneIDs, [paneC])
        XCTAssertEqual(movedSplit.second.paneIDs, [paneA])
    }

    func testEachEdgeDropUsesExpectedAxisAndOrder() throws {
        let cases: [(PaneDropZone, SplitAxis, Bool)] = [
            (.left, .horizontal, true),
            (.right, .horizontal, false),
            (.top, .vertical, true),
            (.bottom, .vertical, false),
        ]

        for (dropZone, expectedAxis, sourceComesFirst) in cases {
            let source = UUID()
            let target = UUID()
            var layout = SessionLayoutNode.split(PaneSplitNode(
                axis: .horizontal,
                first: .pane(PaneLeaf(paneID: source)),
                second: .pane(PaneLeaf(paneID: target))
            ))

            XCTAssertTrue(layout.rearrangePane(source, relativeTo: target, dropZone: dropZone))
            guard case .split(let split) = layout else {
                return XCTFail("expected split layout for \(dropZone)")
            }
            XCTAssertEqual(split.axis, expectedAxis)
            XCTAssertEqual(split.first.paneIDs, [sourceComesFirst ? source : target])
            XCTAssertEqual(split.second.paneIDs, [sourceComesFirst ? target : source])
        }
    }

    func testSelfDropLeavesLayoutUnchanged() throws {
        let paneA = UUID()
        let paneB = UUID()
        let original = SessionLayoutNode.split(PaneSplitNode(
            axis: .horizontal,
            first: .pane(PaneLeaf(paneID: paneA)),
            second: .pane(PaneLeaf(paneID: paneB))
        ))
        var layout = original

        XCTAssertFalse(layout.rearrangePane(paneA, relativeTo: paneA, dropZone: .bottom))
        XCTAssertEqual(layout, original)
    }

    func testDropZoneResolverUsesCenterAndNearestNormalizedEdge() {
        let size = CGSize(width: 200, height: 100)

        XCTAssertEqual(PaneDropZone.resolve(location: CGPoint(x: 100, y: 50), in: size), .center)
        XCTAssertEqual(PaneDropZone.resolve(location: CGPoint(x: 10, y: 50), in: size), .left)
        XCTAssertEqual(PaneDropZone.resolve(location: CGPoint(x: 190, y: 50), in: size), .right)
        XCTAssertEqual(PaneDropZone.resolve(location: CGPoint(x: 100, y: 5), in: size), .top)
        XCTAssertEqual(PaneDropZone.resolve(location: CGPoint(x: 100, y: 95), in: size), .bottom)
        XCTAssertEqual(PaneDropZone.resolve(location: CGPoint(x: 10, y: 10), in: size), .left)
    }

    @MainActor
    func testControllerRearrangePreservesSessionsAndFocusesDraggedPane() throws {
        let controller = WorkspaceSessionController(workingDirectory: "/tmp")
        defer { controller.terminateAll() }
        let sourcePaneID = try XCTUnwrap(controller.focusedPaneID)
        let sourceSession = controller.ensureSession(for: sourcePaneID)
        controller.splitPane(sourcePaneID, axis: .horizontal)
        let targetPaneID = try XCTUnwrap(controller.focusedPaneID)
        let targetSession = controller.ensureSession(for: targetPaneID)
        var callbackCount = 0
        controller.onPaneStateChanged = { callbackCount += 1 }

        XCTAssertTrue(controller.rearrangePane(
            sourcePaneID,
            relativeTo: targetPaneID,
            dropZone: .center
        ))

        XCTAssertTrue(controller.session(for: sourcePaneID) === sourceSession)
        XCTAssertTrue(controller.session(for: targetPaneID) === targetSession)
        XCTAssertEqual(controller.focusedPaneID, sourcePaneID)
        XCTAssertEqual(callbackCount, 1)
    }

    func testFractionClamping() throws {
        let node = PaneSplitNode(
            axis: .horizontal,
            fraction: 0.05,
            first: .pane(PaneLeaf(paneID: UUID())),
            second: .pane(PaneLeaf(paneID: UUID()))
        )
        XCTAssertGreaterThanOrEqual(node.clampedFraction, 0.12)
    }

    func testReconnectPresentationStates() {
        XCTAssertEqual(
            TerminalReconnectControlState.resolve(isReconnecting: false, reconnectError: nil),
            .enabled
        )
        XCTAssertEqual(
            TerminalReconnectControlState.resolve(isReconnecting: true, reconnectError: nil),
            .reconnecting
        )
        XCTAssertEqual(
            TerminalReconnectControlState.resolve(isReconnecting: false, reconnectError: "failed"),
            .failed
        )
    }

    func testTerminalReconnectPresentationUsesThemeRoles() {
        XCTAssertEqual(TerminalReconnectPresentation.progressRole, .accent)
        XCTAssertEqual(TerminalReconnectPresentation.role(for: .retry), .accent)
        XCTAssertEqual(TerminalReconnectPresentation.role(for: .startShell), .secondaryText)
    }
}
