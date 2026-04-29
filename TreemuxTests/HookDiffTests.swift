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
}
