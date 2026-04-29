import XCTest
@testable import Treemux

final class HookDiffTests: XCTestCase {

    func testIdenticalInputsAllUnchanged() {
        let text = "alpha\nbeta\ngamma"
        let result = HookDiff.compute(current: text, proposed: text)

        XCTAssertEqual(result.before.map(\.text), ["alpha", "beta", "gamma"])
        XCTAssertEqual(result.after.map(\.text),  ["alpha", "beta", "gamma"])
        XCTAssertTrue(result.before.allSatisfy { $0.mark == .unchanged })
        XCTAssertTrue(result.after.allSatisfy  { $0.mark == .unchanged })
    }

    func testPureAdditions() {
        let result = HookDiff.compute(
            current:  "alpha\nbeta",
            proposed: "alpha\nbeta\ngamma\ndelta"
        )
        XCTAssertEqual(result.before.map(\.mark), [.unchanged, .unchanged])
        XCTAssertEqual(result.after.map(\.mark),  [.unchanged, .unchanged, .added, .added])
        XCTAssertEqual(result.after.map(\.text),  ["alpha", "beta", "gamma", "delta"])
    }

    func testPureRemovals() {
        let result = HookDiff.compute(
            current:  "alpha\nbeta\ngamma\ndelta",
            proposed: "alpha\nbeta"
        )
        XCTAssertEqual(result.before.map(\.mark), [.unchanged, .unchanged, .removed, .removed])
        XCTAssertEqual(result.before.map(\.text), ["alpha", "beta", "gamma", "delta"])
        XCTAssertEqual(result.after.map(\.mark),  [.unchanged, .unchanged])
    }

    func testMixedInsertAndDelete() {
        let result = HookDiff.compute(
            current:  "a\nb\nc\nd",
            proposed: "a\nB\nc\nE"
        )
        XCTAssertEqual(result.before.map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(result.before.map(\.mark),
                       [.unchanged, .removed, .unchanged, .removed])
        XCTAssertEqual(result.after.map(\.text), ["a", "B", "c", "E"])
        XCTAssertEqual(result.after.map(\.mark),
                       [.unchanged, .added, .unchanged, .added])
    }
}
