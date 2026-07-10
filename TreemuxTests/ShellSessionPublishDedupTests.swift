//
//  ShellSessionPublishDedupTests.swift
//  TreemuxTests
//

import XCTest
import AppKit
@testable import Treemux

/// Minimal surface fake: records callbacks, no real terminal.
@MainActor
private final class FakeSurfaceController: ManagedTerminalSessionSurfaceController {
    var resolvedEngine: TerminalEngineKind { .libghosttyPreferred }
    let view = NSView()
    var onResize: ((Int, Int) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String?) -> Void)?
    var onFocus: (() -> Void)?
    var onStatusChange: ((TerminalSurfaceStatusSnapshot) -> Void)?
    var onDesktopNotification: ((String, String?) -> Void)?
    var onUserInput: (() -> Void)?
    var managedPID: Int32? { nil }
    var isManagedSessionRunning: Bool { false }
    var needsConfirmQuit: Bool { false }
    var onProcessExit: ((Int32?) -> Void)?
    func sendText(_ text: String) {}
    func focus() {}
    func setFocused(_ isFocused: Bool) {}
    func beginSearch(initialText: String?) {}
    func updateSearch(_ text: String) {}
    func searchNext() {}
    func searchPrevious() {}
    func endSearch() {}
    func toggleReadOnly() {}
    func updateLaunchConfiguration(_ configuration: TerminalLaunchConfiguration) {}
    func startManagedSessionIfNeeded() {}
    func restartManagedSession() {}
    func terminateManagedSession() {}
}

/// All-property counter for a ShellSession (see ObservationChangeCounter in
/// ObservableBridgeTests.swift) — faithful to the old object-level counting.
@MainActor
private func makeCounter(for session: ShellSession) -> ObservationChangeCounter {
    ObservationChangeCounter {
        _ = session.title
        _ = session.preferredWorkingDirectory
        _ = session.reportedWorkingDirectory
        _ = session.lifecycle
        _ = session.exitCode
        _ = session.pid
        _ = session.rows
        _ = session.cols
        _ = session.surfaceStatus
        _ = session.detectedTmuxSession
    }
}

@MainActor
final class ShellSessionPublishDedupTests: XCTestCase {
    private func makeSession(surface: FakeSurfaceController) -> ShellSession {
        ShellSession(
            backendConfiguration: .localShell(LocalShellConfig(shellPath: "/bin/zsh", arguments: ["--login"])),
            preferredWorkingDirectory: "/tmp",
            surfaceController: surface
        )
    }

    func testRepeatedIdenticalResizeDoesNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        let counter = makeCounter(for: session)
        defer { counter.stop() }

        surface.onResize?(120, 40)
        let afterFirst = counter.count
        surface.onResize?(120, 40)   // same values: must be a no-op
        surface.onResize?(120, 40)
        XCTAssertEqual(counter.count, afterFirst, "identical resize must not republish")
        surface.onResize?(121, 40)   // changed: must publish again
        XCTAssertGreaterThan(counter.count, afterFirst)
    }

    func testIdenticalStatusSnapshotDoesNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        let counter = makeCounter(for: session)
        defer { counter.stop() }

        // Must differ from the session's initial default snapshot, otherwise the
        // first delivery is itself deduped and afterFirst stays 0 vacuously.
        var snap = TerminalSurfaceStatusSnapshot()
        snap.isReadOnly = true
        surface.onStatusChange?(snap)
        let afterFirst = counter.count
        XCTAssertGreaterThan(afterFirst, 0, "first change must be observed — guards against a dead counter")
        surface.onStatusChange?(snap)
        XCTAssertEqual(counter.count, afterFirst)
    }

    func testIdenticalTitleAndCwdDoNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        let counter = makeCounter(for: session)
        defer { counter.stop() }

        surface.onTitleChange?("zsh")
        surface.onWorkingDirectoryChange?("/tmp")
        let afterFirst = counter.count
        XCTAssertGreaterThan(afterFirst, 0, "first change must be observed — guards against a dead counter")
        surface.onTitleChange?("zsh")
        surface.onWorkingDirectoryChange?("/tmp")
        XCTAssertEqual(counter.count, afterFirst)
    }
}
