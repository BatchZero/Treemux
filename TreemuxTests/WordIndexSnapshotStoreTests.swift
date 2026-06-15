//
//  WordIndexSnapshotStoreTests.swift
//  TreemuxTests

import XCTest
@testable import Treemux

final class WordIndexSnapshotStoreTests: XCTestCase {
    func test_suggestions_rankByFrequencyThenAlpha() {
        let store = WordIndexSnapshotStore()
        store.replace(["alpha": 3, "alacrity": 1, "able": 1])
        XCTAssertEqual(store.suggestions(prefix: "al", limit: 10), ["alpha", "alacrity"])
    }

    func test_suggestions_excludesExactPrefixMatch() {
        let store = WordIndexSnapshotStore()
        store.replace(["count": 2, "counter": 1])
        XCTAssertEqual(store.suggestions(prefix: "count", limit: 10), ["counter"])
    }

    func test_suggestions_caseInsensitivePrefix() {
        let store = WordIndexSnapshotStore()
        store.replace(["Buffer": 1])
        XCTAssertEqual(store.suggestions(prefix: "buf", limit: 10), ["Buffer"])
    }

    func test_emptyPrefix_returnsNothing() {
        let store = WordIndexSnapshotStore()
        store.replace(["alpha": 1])
        XCTAssertEqual(store.suggestions(prefix: "", limit: 10), [])
    }

    func test_replace_overwritesPreviousSnapshot() {
        let store = WordIndexSnapshotStore()
        store.replace(["alpha": 1])
        store.replace(["beta": 1])
        XCTAssertEqual(store.suggestions(prefix: "al", limit: 10), [])
        XCTAssertEqual(store.suggestions(prefix: "be", limit: 10), ["beta"])
    }
}
