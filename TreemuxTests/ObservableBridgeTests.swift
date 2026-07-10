//
//  ObservableBridgeTests.swift
//  TreemuxTests
//
//  Pins the PassthroughSubject bridges that replace Combine's projected
//  @Published publishers after the @Observable migration. Non-SwiftUI
//  observers (WindowContext, AppDelegate) rely on: fires on every post-init
//  assignment, never replays an initial value.

import XCTest
import Combine
import Observation
@testable import Treemux

/// Counts Observation change notifications over the properties read by the
/// `reading` closure — the faithful replacement for the old object-level
/// `objectWillChange.sink { publishes += 1 }` counting (used by
/// ShellSessionPublishDedupTests and EditorBufferIsolationTests; internal on
/// purpose so those files share it). onChange fires synchronously at willSet
/// on the mutating (main) actor and is one-shot, so it re-arms synchronously;
/// back-to-back mutations inside one callback are each counted. NOTE: fires
/// only for @Observable types — against a not-yet-migrated ObservableObject
/// it never fires, which is what makes rewrite-test-first runs red.
@MainActor
final class ObservationChangeCounter {
    private(set) var count = 0
    private var stopped = false
    private let read: () -> Void
    init(reading read: @escaping () -> Void) {
        self.read = read
        arm()
    }
    func stop() { stopped = true }
    private func arm() {
        withObservationTracking(read) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.count += 1
                self.arm()
            }
        }
    }
}

@MainActor
final class ObservableBridgeTests: XCTestCase {

    func testActiveThemePublisherFiresOnSetActiveThemeAndReload() {
        let manager = ThemeManager(activeThemeID: "treemux-dark")
        var received: [String] = []
        let sub = manager.activeThemePublisher.sink { received.append($0.id) }
        defer { sub.cancel() }

        XCTAssertEqual(received, [], "bridge must not replay the initial theme")
        guard let other = manager.availableThemes.first(where: { $0.id != manager.activeTheme.id }) else {
            return XCTFail("expected at least two available themes")
        }
        manager.setActiveTheme(other.id)
        XCTAssertEqual(received.last, other.id)
        let countAfterSet = received.count
        manager.reloadThemes()   // also assigns activeTheme -> must fire too
        XCTAssertEqual(received.count, countAfterSet + 1,
                       "reloadThemes assigns activeTheme and must fire the bridge")
    }
}
