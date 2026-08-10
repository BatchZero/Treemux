//
//  ScrollSyncTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class ScrollSyncMetricsTests: XCTestCase {
    func testFractionUsesScrollableHeight() {
        XCTAssertEqual(
            ScrollSyncMetrics.fraction(offsetY: 300, contentHeight: 1_000, viewportHeight: 400),
            0.5,
            accuracy: 0.000_001
        )
    }

    func testFractionClampsAtBothEdges() {
        XCTAssertEqual(ScrollSyncMetrics.fraction(offsetY: -20, contentHeight: 1_000, viewportHeight: 400), 0)
        XCTAssertEqual(ScrollSyncMetrics.fraction(offsetY: 900, contentHeight: 1_000, viewportHeight: 400), 1)
    }

    func testFractionIsZeroWhenContentDoesNotScroll() {
        XCTAssertEqual(ScrollSyncMetrics.fraction(offsetY: 50, contentHeight: 300, viewportHeight: 400), 0)
    }

    func testOffsetUsesClampedFraction() {
        XCTAssertEqual(ScrollSyncMetrics.offsetY(fraction: 0.5, contentHeight: 1_000, viewportHeight: 400), 300)
        XCTAssertEqual(ScrollSyncMetrics.offsetY(fraction: -1, contentHeight: 1_000, viewportHeight: 400), 0)
        XCTAssertEqual(ScrollSyncMetrics.offsetY(fraction: 2, contentHeight: 1_000, viewportHeight: 400), 600)
    }
}

@MainActor
final class ScrollSyncStateTests: XCTestCase {
    func testPublishRecordsOriginAndClampsFraction() {
        let sync = ScrollSync()

        sync.publish(fraction: 1.5, from: .source)

        XCTAssertEqual(sync.fraction, 1)
        XCTAssertEqual(sync.driver, .source)
        XCTAssertEqual(sync.revision, 1)
    }

    func testPublishingSameFractionStillAdvancesRevision() {
        let sync = ScrollSync()
        sync.publish(fraction: 0.25, from: .source)

        sync.publish(fraction: 0.25, from: .render)

        XCTAssertEqual(sync.fraction, 0.25)
        XCTAssertEqual(sync.driver, .render)
        XCTAssertEqual(sync.revision, 2)
    }

    func testFinishClearsOnlyTheMatchingOrigin() {
        let sync = ScrollSync()
        sync.publish(fraction: 0.5, from: .source)

        sync.finish(.render)
        XCTAssertEqual(sync.driver, .source)

        sync.finish(.source)
        XCTAssertEqual(sync.driver, .none)
    }
}
