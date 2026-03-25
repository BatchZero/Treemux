import XCTest
@testable import Treemux

final class PaneLayoutTests: XCTestCase {

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

    func testFractionClamping() throws {
        let node = PaneSplitNode(
            axis: .horizontal,
            fraction: 0.05,
            first: .pane(PaneLeaf(paneID: UUID())),
            second: .pane(PaneLeaf(paneID: UUID()))
        )
        XCTAssertGreaterThanOrEqual(node.clampedFraction, 0.12)
    }
}
