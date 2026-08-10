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
    var calls: [String] = []
    var latestLaunchConfiguration: TerminalLaunchConfiguration?
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
    func focus() { calls.append("focus") }
    func setFocused(_ isFocused: Bool) { calls.append("focused:\(isFocused)") }
    func beginSearch(initialText: String?) {}
    func updateSearch(_ text: String) {}
    func searchNext() {}
    func searchPrevious() {}
    func endSearch() {}
    func toggleReadOnly() {}
    func updateLaunchConfiguration(_ configuration: TerminalLaunchConfiguration) {
        latestLaunchConfiguration = configuration
        calls.append("update")
    }
    func startManagedSessionIfNeeded() { calls.append("start") }
    func restartManagedSession() {}
    func terminateManagedSession() { calls.append("terminate") }
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
private final class ControlledShellPIDResolver {
    private(set) var continuations: [CheckedContinuation<Int32?, Never>] = []

    func resolve(paneID _: String) async -> Int32? {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForAttemptCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func completeAttempt(_ index: Int, with pid: Int32?) {
        continuations[index].resume(returning: pid)
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

    func testReconnectReattachesDetectedTmuxAndClearsTransientState() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        surface.onTitleChange?("tmux attach -t dev")
        surface.onWorkingDirectoryChange?("/tmp/project")
        surface.calls.removeAll()

        session.reconnect()

        XCTAssertEqual(surface.calls, ["terminate", "update", "start", "focused:false"])
        XCTAssertTrue(
            surface.latestLaunchConfiguration?.command.arguments.joined(separator: " ").contains("dev") == true
        )
        XCTAssertNil(session.reportedWorkingDirectory)
        XCTAssertNil(session.detectedTmuxSession)
        XCTAssertTrue(session.isReconnecting)
        XCTAssertNil(session.reconnectError)
    }

    func testReconnectIsSuppressedWhileAlreadyInProgress() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)

        session.reconnect()
        let firstCalls = surface.calls
        session.reconnect()

        XCTAssertEqual(surface.calls, firstCalls)
    }

    func testReconnectRestoresFocusedPane() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        session.setFocused(true)
        surface.calls.removeAll()

        session.reconnect()

        XCTAssertEqual(surface.calls.suffix(2), ["focused:true", "focus"])
    }

    func testInitialTmuxRestoreFailureOffersRecovery() {
        let surface = FakeSurfaceController()
        let session = ShellSession(
            backendConfiguration: .localShell(LocalShellConfig(
                shellPath: "/bin/fish",
                arguments: ["-l"]
            )),
            preferredWorkingDirectory: "/tmp",
            surfaceController: surface,
            initialLaunchBackend: .tmuxAttach(TmuxAttachConfig(
                sessionName: "dev",
                windowIndex: nil,
                isRemote: false,
                sshTarget: nil
            )),
            initialDetectedTmuxSession: "dev"
        )

        session.startIfNeeded()
        surface.onProcessExit?(1)

        XCTAssertNotNil(session.reconnectError)
        surface.calls.removeAll()
        session.startShellAfterReconnectFailure()

        XCTAssertEqual(surface.latestLaunchConfiguration?.command.executablePath, "/bin/fish")
        XCTAssertEqual(surface.latestLaunchConfiguration?.command.arguments, ["-l"])
    }

    func testOriginalTmuxAttachInitialFailureOffersRecovery() {
        let surface = FakeSurfaceController()
        let backend = SessionBackendConfiguration.tmuxAttach(TmuxAttachConfig(
            sessionName: "dev",
            windowIndex: nil,
            isRemote: false,
            sshTarget: nil
        ))
        let session = ShellSession(
            backendConfiguration: backend,
            preferredWorkingDirectory: "/tmp",
            surfaceController: surface
        )

        session.startIfNeeded()
        surface.onProcessExit?(1)

        XCTAssertNotNil(session.reconnectError)
    }

    func testFailedTmuxReconnectCanFallBackToOriginalShell() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        surface.onTitleChange?("tmux attach -t dev")
        session.reconnect()
        surface.onProcessExit?(1)

        XCTAssertFalse(session.isReconnecting)
        XCTAssertNotNil(session.reconnectError)
        surface.calls.removeAll()

        session.startShellAfterReconnectFailure()

        XCTAssertEqual(surface.calls.prefix(3), ["terminate", "update", "start"])
        XCTAssertFalse(
            surface.latestLaunchConfiguration?.command.arguments.joined(separator: " ").contains("dev") == true
        )
        XCTAssertNil(session.reconnectError)
    }

    func testFailedTmuxReconnectCanRetrySameAttachment() {
        let surface = FakeSurfaceController()
        let session = makeSession(surface: surface)
        surface.onTitleChange?("tmux attach -t dev")
        session.reconnect()
        surface.onProcessExit?(1)
        surface.calls.removeAll()

        session.retryReconnect()

        XCTAssertEqual(surface.calls.prefix(3), ["terminate", "update", "start"])
        XCTAssertTrue(
            surface.latestLaunchConfiguration?.command.arguments.joined(separator: " ").contains("dev") == true
        )
        XCTAssertNil(session.reconnectError)
        XCTAssertTrue(session.isReconnecting)
    }

    func testStalePIDResolutionCannotFinishNewRetry() async {
        let surface = FakeSurfaceController()
        let resolver = ControlledShellPIDResolver()
        let session = ShellSession(
            backendConfiguration: .localShell(LocalShellConfig(
                shellPath: "/bin/zsh",
                arguments: ["--login"]
            )),
            preferredWorkingDirectory: "/tmp",
            surfaceController: surface,
            shellPIDResolver: resolver.resolve
        )
        surface.onTitleChange?("tmux attach -t dev")

        session.reconnect()
        await resolver.waitForAttemptCount(1)
        surface.onProcessExit?(1)
        session.retryReconnect()
        await resolver.waitForAttemptCount(2)

        resolver.completeAttempt(0, with: 111)
        await Task.yield()

        XCTAssertTrue(session.isReconnecting)
        XCTAssertNil(session.pid)

        resolver.completeAttempt(1, with: 222)
        while session.isReconnecting {
            await Task.yield()
        }

        XCTAssertEqual(session.pid, 222)
    }

    func testRemoteTmuxExitAfterPIDResolutionTimeoutStillOffersRecovery() async {
        let surface = FakeSurfaceController()
        let sshTarget = SSHTarget(
            host: "server.example.com",
            port: 22,
            user: "developer",
            identityFile: nil,
            displayName: "Server",
            remotePath: "/srv/project"
        )
        let session = ShellSession(
            backendConfiguration: .ssh(SSHSessionConfig(target: sshTarget, remoteCommand: nil)),
            preferredWorkingDirectory: "/tmp",
            surfaceController: surface,
            shellPIDResolver: { _ in nil }
        )
        surface.onTitleChange?("tmux attach -t dev")

        session.reconnect()
        while session.isReconnecting {
            await Task.yield()
        }
        XCTAssertNil(session.reconnectError)

        surface.onProcessExit?(1)

        XCTAssertNotNil(session.reconnectError)
    }
}
