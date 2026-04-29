//
//  BufferWordIndexTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class BufferWordIndexTests: XCTestCase {
    func test_extractsIdentifiers_excludingShortAndNumbers() async {
        let idx = BufferWordIndex()
        let id = UUID()
        await idx.update(bufferID: id, contents: "let foo = 42; var bar = 'hello'; a")
        let s = await idx.suggestions(prefix: "fo", limit: 10)
        XCTAssertTrue(s.contains("foo"))
        XCTAssertFalse(s.contains("a"), "single-char identifiers excluded by regex")
        XCTAssertFalse(s.contains("42"), "numbers excluded")
    }

    func test_multipleBuffers_unionAndRanking() async {
        let idx = BufferWordIndex()
        let a = UUID()
        let b = UUID()
        await idx.update(bufferID: a, contents: "fooBar fooBaz fooBar")
        await idx.update(bufferID: b, contents: "fooQux")
        let s = await idx.suggestions(prefix: "foo", limit: 10)
        XCTAssertEqual(Set(s), ["fooBar", "fooBaz", "fooQux"])
    }

    func test_removeBuffer_dropsItsWords() async {
        let idx = BufferWordIndex()
        let id = UUID()
        await idx.update(bufferID: id, contents: "alpha beta gamma")
        let firstSuggestions = await idx.suggestions(prefix: "a", limit: 10)
        XCTAssertEqual(Set(firstSuggestions), ["alpha"])
        await idx.remove(bufferID: id)
        let afterRemoval = await idx.suggestions(prefix: "a", limit: 10)
        XCTAssertEqual(afterRemoval, [])
    }

    func test_suggestions_excludeExactPrefix() async {
        // Typing the full word shouldn't suggest the same word back.
        let idx = BufferWordIndex()
        let id = UUID()
        await idx.update(bufferID: id, contents: "private privateSet privateValue")
        let s = await idx.suggestions(prefix: "private", limit: 10)
        XCTAssertFalse(s.contains("private"))
        XCTAssertTrue(s.contains("privateSet"))
    }

    func test_suggestionRanking_byFrequency() async {
        let idx = BufferWordIndex()
        let a = UUID()
        let b = UUID()
        await idx.update(bufferID: a, contents: "common common rare")
        await idx.update(bufferID: b, contents: "common")
        let s = await idx.suggestions(prefix: "c", limit: 10)
        XCTAssertEqual(s.first, "common")
    }
}
