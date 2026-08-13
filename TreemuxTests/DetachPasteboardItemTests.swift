//
//  DetachPasteboardItemTests.swift
//  TreemuxTests
//
//  Unit tests for `DetachPasteboardItem`. Verifies that:
//  - the detach type carries a JSON round-trip of the `DetachedNodeRef`, and
//  - legacy reorder types still carry their raw string (so in-list reorder
//    keeps working), and
//  - `writableTypes` advertises both the detach type and the legacy types.
//

import AppKit
import XCTest
@testable import Treemux

final class DetachPasteboardItemTests: XCTestCase {

    // MARK: - Outline drag lifecycle wiring

    @MainActor
    func testSidebarCoordinatorImplementsOutlineViewDragEndedDelegateCallback() {
        let coordinator = SidebarCoordinator()
        let selector = NSSelectorFromString(
            "outlineView:draggingSession:endedAtPoint:operation:"
        )

        XCTAssertTrue(
            coordinator.responds(to: selector),
            "NSOutlineView sends drag completion through the outlineView delegate selector"
        )
    }

    func testDragOutsideOutlineWithNoCompletedOperationDetaches() {
        XCTAssertTrue(SidebarCoordinator.shouldDetachDrag(
            operation: [],
            releasePoint: NSPoint(x: 500, y: 200),
            outlineRectInScreen: NSRect(x: 0, y: 0, width: 250, height: 600)
        ))
    }

    func testCompletedReorderOrReleaseInsideOutlineDoesNotDetach() {
        let rect = NSRect(x: 0, y: 0, width: 250, height: 600)

        XCTAssertFalse(SidebarCoordinator.shouldDetachDrag(
            operation: .move,
            releasePoint: NSPoint(x: 500, y: 200),
            outlineRectInScreen: rect
        ))
        XCTAssertFalse(SidebarCoordinator.shouldDetachDrag(
            operation: [],
            releasePoint: NSPoint(x: 100, y: 200),
            outlineRectInScreen: rect
        ))
    }

    // MARK: - writableTypes

    func testWritableTypesIncludesDetachAndLegacyTypes() {
        let legacy = NSPasteboard.PasteboardType("com.treemux.workspace.ids")
        let item = DetachPasteboardItem(
            ref: .workspace(UUID()),
            legacyReorderPayload: [(legacy, "deadbeef")]
        )
        let types = item.writableTypes(for: nil)
        XCTAssertEqual(types.first, DetachPasteboardItem.detachType,
                       "detach type should be advertised first")
        XCTAssertTrue(types.contains(legacy),
                      "legacy reorder type should be advertised for reorder compatibility")
    }

    func testWritableTypesForWorktreeHasOnlyDetachType() {
        // Worktree carries no legacy reorder payload.
        let item = DetachPasteboardItem(
            ref: .worktree(workspaceID: UUID(), worktreeID: UUID())
        )
        let types = item.writableTypes(for: nil)
        XCTAssertEqual(types, [DetachPasteboardItem.detachType])
    }

    // MARK: - Detach payload round-trip

    func testDetachPayloadRoundTripsWorkspaceRef() throws {
        let id = UUID()
        let item = DetachPasteboardItem(ref: .workspace(id))
        let plist = item.pasteboardPropertyList(forType: DetachPasteboardItem.detachType)
        let json = try XCTUnwrap(plist as? String)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .workspace(id))
    }

    func testDetachPayloadRoundTripsWorktreeRef() throws {
        let wsID = UUID()
        let wtID = UUID()
        let item = DetachPasteboardItem(ref: .worktree(workspaceID: wsID, worktreeID: wtID))
        let plist = item.pasteboardPropertyList(forType: DetachPasteboardItem.detachType)
        let json = try XCTUnwrap(plist as? String)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .worktree(workspaceID: wsID, worktreeID: wtID))
    }

    func testDetachPayloadRoundTripsRemoteGroupRef() throws {
        let item = DetachPasteboardItem(ref: .remoteGroup("srv|user"))
        let plist = item.pasteboardPropertyList(forType: DetachPasteboardItem.detachType)
        let json = try XCTUnwrap(plist as? String)
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .remoteGroup("srv|user"))
    }

    // MARK: - Legacy payload passthrough

    func testLegacyTypeReturnsRawString() {
        let legacy = NSPasteboard.PasteboardType("com.treemux.workspace.ids")
        let id = UUID()
        let item = DetachPasteboardItem(
            ref: .workspace(id),
            legacyReorderPayload: [(legacy, id.uuidString)]
        )
        let plist = item.pasteboardPropertyList(forType: legacy)
        XCTAssertEqual(plist as? String, id.uuidString,
                       "legacy reorder type should return the raw UUID string")
    }

    func testUnknownTypeReturnsNil() {
        let legacy = NSPasteboard.PasteboardType("com.treemux.workspace.ids")
        let item = DetachPasteboardItem(
            ref: .workspace(UUID()),
            legacyReorderPayload: [(legacy, "x")]
        )
        let unknown = NSPasteboard.PasteboardType("com.treemux.unknown")
        XCTAssertNil(item.pasteboardPropertyList(forType: unknown))
    }

    // MARK: - End-to-end via a real NSPasteboard

    func testWritingToRealPasteboardPreservesBothPayloads() throws {
        let legacy = NSPasteboard.PasteboardType("com.treemux.workspace.ids")
        let id = UUID()
        let item = DetachPasteboardItem(
            ref: .workspace(id),
            legacyReorderPayload: [(legacy, id.uuidString)]
        )

        let pb = NSPasteboard(name: .drag)
        pb.clearContents()
        pb.writeObjects([item])

        // Legacy reorder payload survives (this is what validateDrop/acceptDrop read).
        let legacyString = pb.string(forType: legacy)
        XCTAssertEqual(legacyString, id.uuidString)

        // Detach payload survives and round-trips.
        let detachJSON = try XCTUnwrap(pb.string(forType: DetachPasteboardItem.detachType))
        let decoded = try JSONDecoder().decode(DetachedNodeRef.self, from: Data(detachJSON.utf8))
        XCTAssertEqual(decoded, .workspace(id))
    }
}
