//
//  ShellSessionPublishDedupTests.swift
//  TreemuxTests
//

import XCTest
import Combine
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
        var publishes = 0
        let sub = session.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        surface.onResize?(120, 40)
        let afterFirst = publishes
        surface.onResize?(120, 40)   // same values: must be a no-op
        surface.onResize?(120, 40)
        XCTAssertEqual(publishes, afterFirst, "identical resize must not republish")
        surface.onResize?(121, 40)   // changed: must publish again
        XCTAssertGreaterThan(publishes, afterFirst)
    }

    func testIdenticalStatusSnapshotDoesNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        var publishes = 0
        let sub = session.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        let snap = TerminalSurfaceStatusSnapshot()
        surface.onStatusChange?(snap)
        let afterFirst = publishes
        surface.onStatusChange?(snap)
        XCTAssertEqual(publishes, afterFirst)
    }

    func testIdenticalTitleAndCwdDoNotRepublish() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        var publishes = 0
        let sub = session.objectWillChange.sink { _ in publishes += 1 }
        defer { sub.cancel() }

        surface.onTitleChange?("zsh")
        surface.onWorkingDirectoryChange?("/tmp")
        let afterFirst = publishes
        surface.onTitleChange?("zsh")
        surface.onWorkingDirectoryChange?("/tmp")
        XCTAssertEqual(publishes, afterFirst)
    }
}
