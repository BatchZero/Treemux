import XCTest
@testable import Treemux

final class PerfSignpostTests: XCTestCase {
    // Signpost emission is fire-and-forget; the contract we can test is that
    // the API is callable in any order without crashing and returns a state
    // token usable exactly once.
    func testBeginEndEventDoNotCrash() {
        let state = PerfSignpost.begin("git-status-refresh")
        PerfSignpost.event("tree-generation-bump")
        PerfSignpost.end("git-status-refresh", state)
    }
}
