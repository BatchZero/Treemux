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

    func testLocalePublisherDeliversNewLocaleWithoutReplay() {
        let domainName = Bundle.main.bundleIdentifier!
        let saved = UserDefaults.standard.persistentDomain(forName: domainName)?["AppleLanguages"]
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
        let manager = LanguageManager(languageCode: "en")
        var received: [Locale] = []
        let sub = manager.localePublisher.sink { received.append($0) }
        defer { sub.cancel() }

        XCTAssertEqual(received, [], "bridge must not replay the initial locale")
        manager.apply(languageCode: "zh-Hans")
        XCTAssertEqual(received.last?.identifier, "zh-Hans",
                       "bridge must deliver the NEW locale as payload")
    }

    func testSystemLanguageUsesGlobalPreferenceInsteadOfStaleAppOverride() throws {
        let domainName = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let saved = UserDefaults.standard.persistentDomain(forName: domainName)?["AppleLanguages"]
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }

        // Simulate the stale per-app override left by explicitly choosing English.
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        let manager = LanguageManager(
            languageCode: "system",
            systemLanguages: { ["zh-Hans-US", "en-US"] }
        )
        let expected = Locale(identifier: "zh-Hans-US")

        XCTAssertEqual(manager.locale.language.languageCode, expected.language.languageCode)
        XCTAssertEqual(manager.locale.language.script, expected.language.script)
        let appOverride = UserDefaults.standard.persistentDomain(forName: domainName)?["AppleLanguages"]
        XCTAssertNil(appOverride)
    }

    func testSettingsPublisherFiresOnMutationWithoutReplay() {
        let store = WorkspaceStore()
        var fires = 0
        let sub = store.settingsPublisher.sink { _ in fires += 1 }
        defer { sub.cancel() }

        XCTAssertEqual(fires, 0, "bridge must not replay initial settings")
        var s = store.settings
        s.showDefaultTerminal.toggle()
        store.settings = s
        XCTAssertEqual(fires, 1, "one assignment -> exactly one bridge fire")
    }
}
