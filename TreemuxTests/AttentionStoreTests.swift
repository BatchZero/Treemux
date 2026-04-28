import XCTest
@testable import Treemux

@MainActor
final class AttentionStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AttentionStore.shared.resetForTest()
    }

    func testSetAttentionStoresState() {
        let id = UUID()
        AttentionStore.shared.setAttention(paneID: id, state: .done)
        XCTAssertEqual(AttentionStore.shared.state(for: id), .done)
    }

    func testSetNoneRemovesEntry() {
        let id = UUID()
        AttentionStore.shared.setAttention(paneID: id, state: .input)
        AttentionStore.shared.setAttention(paneID: id, state: .none)
        XCTAssertEqual(AttentionStore.shared.state(for: id), .none)
        XCTAssertTrue(AttentionStore.shared.attentive.isEmpty)
    }

    func testClearRemovesPane() {
        let id = UUID()
        AttentionStore.shared.setAttention(paneID: id, state: .done)
        AttentionStore.shared.clear(paneID: id)
        XCTAssertEqual(AttentionStore.shared.state(for: id), .none)
    }

    func testHasAttentionForPaneIDs() {
        let a = UUID(); let b = UUID(); let c = UUID()
        AttentionStore.shared.setAttention(paneID: b, state: .input)
        XCTAssertFalse(AttentionStore.shared.hasAttention(in: [a]))
        XCTAssertTrue(AttentionStore.shared.hasAttention(in: [a, b, c]))
    }

    func testBulkClear() {
        let a = UUID(); let b = UUID()
        AttentionStore.shared.setAttention(paneID: a, state: .done)
        AttentionStore.shared.setAttention(paneID: b, state: .input)
        AttentionStore.shared.clear(paneIDs: [a, b])
        XCTAssertTrue(AttentionStore.shared.attentive.isEmpty)
    }
}
