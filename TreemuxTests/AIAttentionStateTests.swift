import XCTest
@testable import Treemux

final class AIAttentionStateTests: XCTestCase {

    func testParseDoneTitle() {
        XCTAssertEqual(AIAttentionState.parse(notificationTitle: "treemux:done"), .done)
    }

    func testParseInputTitle() {
        XCTAssertEqual(AIAttentionState.parse(notificationTitle: "treemux:input"), .input)
    }

    func testParseUnrelatedTitleReturnsNil() {
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "Build finished"))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: ""))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "treemux:"))
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "treemux:bogus"))
    }

    func testCaseInsensitivePrefixIsNotAccepted() {
        XCTAssertNil(AIAttentionState.parse(notificationTitle: "TREEMUX:done"))
    }

    @MainActor
    func testShellSessionFocusTransitionClearsAttention() {
        let backend = SessionBackendConfiguration.localShell(
            LocalShellConfig(shellPath: "/bin/zsh", arguments: [])
        )
        let session = ShellSession(
            id: UUID(),
            backendConfiguration: backend,
            preferredWorkingDirectory: NSTemporaryDirectory()
        )
        session.applyDesktopNotificationFromTest(title: "treemux:input", body: nil)
        XCTAssertEqual(session.aiAttention, .input)

        session.setFocused(true)
        XCTAssertEqual(session.aiAttention, .none)
    }

    @MainActor
    func testFocusClearsAttentionEvenIfAlreadyFocused() {
        let backend = SessionBackendConfiguration.localShell(
            LocalShellConfig(shellPath: "/bin/zsh", arguments: [])
        )
        let session = ShellSession(
            id: UUID(),
            backendConfiguration: backend,
            preferredWorkingDirectory: NSTemporaryDirectory()
        )
        session.setFocused(true)
        session.applyDesktopNotificationFromTest(title: "treemux:input", body: nil)
        XCTAssertEqual(session.aiAttention, .input)

        // Calling setFocused(true) again on an already-focused session must clear.
        session.setFocused(true)
        XCTAssertEqual(session.aiAttention, .none)
    }

    @MainActor
    func testClearAIAttentionDirectlyResetsState() {
        let backend = SessionBackendConfiguration.localShell(
            LocalShellConfig(shellPath: "/bin/zsh", arguments: [])
        )
        let session = ShellSession(
            id: UUID(),
            backendConfiguration: backend,
            preferredWorkingDirectory: NSTemporaryDirectory()
        )
        session.applyDesktopNotificationFromTest(title: "treemux:done", body: nil)
        XCTAssertEqual(session.aiAttention, .done)

        session.clearAIAttention()
        XCTAssertEqual(session.aiAttention, .none)
    }
}
