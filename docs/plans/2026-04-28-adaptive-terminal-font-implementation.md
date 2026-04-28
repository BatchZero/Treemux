# Adaptive Terminal Font Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make terminal font size auto-adapt across displays of different effective PPI so the glyph's physical size stays consistent, with `⌘= / ⌘- / ⌘0` and Settings buttons providing a hidden-anchor offset that applies globally.

**Architecture:** A new pure `AdaptiveFontSizeCalculator` enum holds the formula `(BASE + offset) × currentPPI / REF_PPI`, where `BASE = 14`, `REF_PPI = 109`, `offset ∈ [-8, +12]`. Each `TreemuxGhosttySurfaceView` recomputes its own font size on `viewDidMoveToWindow` / `viewDidChangeBackingProperties` / `setFrameSize` / `NSWindow.didChangeScreenNotification` / `treemuxTerminalSettingsDidChange`, and pushes via `ghostty_surface_binding_action(surface, "set_font_size:N", _)`. `TerminalSettings.fontSize` is migrated to `fontSizeOffset` (custom Codable). The Ghostty global config no longer carries a `font-size` line — surfaces own it.

**Tech Stack:** Swift 5 / AppKit / SwiftUI / Combine / GhosttyKit C API / XCTest. macOS only.

**Pre-flight:**
- Worktree: `/Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font/`
- Branch: `feat/adaptive-terminal-font`
- Design: `docs/plans/2026-04-28-adaptive-terminal-font-design.md` (already committed)
- Build verification command: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build`
- Test command: `xcodebuild -project Treemux.xcodeproj -scheme Treemux test`

All file paths below are **relative to the worktree root** unless otherwise stated.

---

## Task 1: Create `AdaptiveFontSizeCalculator` (pure formula + tests)

**Files:**
- Create: `Treemux/Domain/AdaptiveFontSizeCalculator.swift`
- Create: `TreemuxTests/AdaptiveFontSizeCalculatorTests.swift`

**Step 1: Write the failing tests first.**

Create `TreemuxTests/AdaptiveFontSizeCalculatorTests.swift`:

```swift
//
//  AdaptiveFontSizeCalculatorTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class AdaptiveFontSizeCalculatorTests: XCTestCase {

    // MARK: - Pure formula

    func testReferencePPI_offsetZero_returnsBase() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 0), 14)
    }

    func testReferencePPI_positiveOffset_addsToBase() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 3), 17)
    }

    func testReferencePPI_negativeOffset_subtractsFromBase() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: -2), 12)
    }

    func testHighPPI_scalesUp() {
        // MBP 14" effective PPI ~121 → 14 × 121 / 109 = 15.54 → 16
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 121, offset: 0), 16)
    }

    func testLowPPI_scalesDown() {
        // 24" 1080p ~92 PPI → 14 × 92 / 109 = 11.81 → 12
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 92, offset: 0), 12)
    }

    func testVeryHighPPI_scalesUpFurther() {
        // 4K 27" "More Space" ~163 PPI → 14 × 163 / 109 = 20.94 → 21
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 163, offset: 0), 21)
    }

    // MARK: - Offset clamp

    func testOffsetAbove_clampsToUpperBound() {
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 99)
        // (14 + 12) × 1 = 26
        XCTAssertEqual(result, 26)
    }

    func testOffsetBelow_clampsToLowerBound() {
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: -99)
        // (14 - 8) × 1 = 6
        XCTAssertEqual(result, 6)
    }

    func testClampOffset_within_returnsValue() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(5), 5)
    }

    func testClampOffset_above_returnsUpper() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(100), 12)
    }

    func testClampOffset_below_returnsLower() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(-100), -8)
    }

    // MARK: - Final clamp [6, 72]

    func testExtremeUpward_clampsTo72() {
        // Max offset+12 baseline, then × 4 PPI ratio still bounded
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 600, offset: 12)
        XCTAssertLessThanOrEqual(result, 72)
    }

    func testExtremeDownward_clampsTo6() {
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 30, offset: -8)
        XCTAssertGreaterThanOrEqual(result, 6)
    }

    // MARK: - Constants

    func testBase_is14() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.base, 14)
    }

    func testReferencePPI_is109() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.referencePPI, 109)
    }

    func testOffsetRange_isMinus8To12() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.offsetRange, -8 ... 12)
    }
}
```

**Step 2: Run the tests to verify they fail.**

Run:
```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux test 2>&1 | tail -30
```

Expected: compile failure — `AdaptiveFontSizeCalculator` is undefined.

**Step 3: Add the new file to the Xcode project.**

The project uses `project.yml` with XcodeGen (see file at root). Inspect it first:

```bash
grep -n "Domain\|AdaptiveFontSize" /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font/project.yml | head -10
```

If `Treemux/Domain/` is included via folder glob (e.g. `path: Treemux` with implicit recursion), no edit is needed. If files are listed explicitly, add the calculator file there. Same for `TreemuxTests/AdaptiveFontSizeCalculatorTests.swift`. After editing `project.yml`, regenerate:

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodegen generate
```

If there's no `xcodegen` and the project just uses folder references, skip this step.

**Step 4: Implement `AdaptiveFontSizeCalculator`.**

Create `Treemux/Domain/AdaptiveFontSizeCalculator.swift`:

```swift
//
//  AdaptiveFontSizeCalculator.swift
//  Treemux
//

import AppKit
import CoreGraphics

/// Computes per-display terminal font sizes so the rendered glyph stays at a
/// consistent physical size as a window moves between monitors with different
/// effective PPI.
///
/// Formula:
///     finalFontSize = clamp(round((BASE + offset) × currentPPI / REF_PPI), 6, 72)
///
/// `BASE` and `REF_PPI` are source-code constants — the user only ever supplies
/// an integer `offset`. Anchoring on a fixed reference PPI lets the absolute
/// "pt" value stay an implementation detail; the offset alone is what gets
/// persisted and exposed to the user.
enum AdaptiveFontSizeCalculator {
    static let base: Int = 14
    static let referencePPI: CGFloat = 109
    static let offsetRange: ClosedRange<Int> = -8 ... 12

    /// Pure formula — used for tests and when PPI is already known.
    static func fontSize(forPPI ppi: CGFloat, offset: Int) -> Int {
        let clamped = clampOffset(offset)
        let raw = CGFloat(base + clamped) * ppi / referencePPI
        let rounded = Int(raw.rounded())
        return max(6, min(72, rounded))
    }

    /// Runtime convenience — falls back to `referencePPI` when the screen has no
    /// usable physical size (AirPlay / virtual / Sidecar / EDID without size).
    static func fontSize(for screen: NSScreen?, offset: Int) -> Int {
        let ppi = effectivePPI(for: screen) ?? referencePPI
        return fontSize(forPPI: ppi, offset: offset)
    }

    static func clampOffset(_ value: Int) -> Int {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// Effective PPI = effective points / physical inches. Returns nil when the
    /// screen does not report usable EDID data.
    static func effectivePPI(for screen: NSScreen?) -> CGFloat? {
        guard let screen else { return nil }
        let displayID = screen.adaptiveDisplayID
        guard displayID != 0 else { return nil }
        let physMm = CGDisplayScreenSize(displayID)
        guard physMm.width > 0 else { return nil }
        let physInches = physMm.width / 25.4
        let effectivePoints = screen.frame.width
        let ppi = effectivePoints / physInches
        return (ppi.isFinite && ppi > 30 && ppi < 600) ? ppi : nil
    }
}

extension NSScreen {
    /// The Core Graphics display id, or 0 when the screen has none. Distinct
    /// from the private `displayID` extension in
    /// `TreemuxGhosttyController.swift` so the two coexist without collision.
    var adaptiveDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) } ?? 0
    }
}
```

**Step 5: Run the tests, expect them to pass.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux test 2>&1 | tail -30
```

Expected: `AdaptiveFontSizeCalculatorTests` 14/14 pass. Other suites still pass.

**Step 6: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/Domain/AdaptiveFontSizeCalculator.swift TreemuxTests/AdaptiveFontSizeCalculatorTests.swift project.yml Treemux.xcodeproj && \
git commit -m "feat: add AdaptiveFontSizeCalculator with PPI-aware formula"
```

---

## Task 2: Migrate `TerminalSettings.fontSize` → `fontSizeOffset`

**Files:**
- Modify: `Treemux/Domain/AppSettings.swift` (`TerminalSettings` struct, lines 25–29)
- Modify: `TreemuxTests/PersistenceTests.swift` (add migration tests)

**Step 1: Add failing migration tests at the bottom of `TreemuxTests/PersistenceTests.swift`.**

Append (before the final `}`):

```swift
    // MARK: - TerminalSettings migration

    func testTerminalSettings_decodesNewFontSizeOffset() throws {
        let json = #"{"defaultShell":"/bin/zsh","fontSizeOffset":3,"cursorStyle":"bar"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 3)
        XCTAssertEqual(decoded.defaultShell, "/bin/zsh")
        XCTAssertEqual(decoded.cursorStyle, "bar")
    }

    func testTerminalSettings_decodesLegacyFontSize_18_toOffset4() throws {
        let json = #"{"defaultShell":"/bin/zsh","fontSize":18,"cursorStyle":"bar"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 4)
    }

    func testTerminalSettings_decodesLegacyFontSize_8_toOffsetMinus6() throws {
        let json = #"{"fontSize":8}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, -6)
    }

    func testTerminalSettings_decodesLegacyFontSize_99_clampsToUpperBound() throws {
        let json = #"{"fontSize":99}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 12)
    }

    func testTerminalSettings_decodesLegacyFontSize_0_clampsToLowerBound() throws {
        let json = #"{"fontSize":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, -8)
    }

    func testTerminalSettings_missingBoth_defaultsToZero() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 0)
    }

    func testTerminalSettings_encode_doesNotWriteLegacyFontSize() throws {
        var settings = TerminalSettings()
        settings.fontSizeOffset = 2
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("fontSizeOffset"), "encoded JSON missing fontSizeOffset")
        XCTAssertFalse(json.contains("\"fontSize\""), "encoded JSON should not contain legacy fontSize key")
    }

    func testTerminalSettings_newOffsetTakesPrecedenceOverLegacyFontSize() throws {
        // If both keys are present, the new key wins.
        let json = #"{"fontSize":20,"fontSizeOffset":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TerminalSettings.self, from: json)
        XCTAssertEqual(decoded.fontSizeOffset, 1)
    }
```

**Step 2: Run tests, verify they fail.**

Expected: compile error (no `fontSizeOffset` field) or runtime decode failures.

**Step 3: Replace `TerminalSettings` in `Treemux/Domain/AppSettings.swift` (lines 25–29).**

Replace:

```swift
/// Terminal emulator appearance and behavior settings.
struct TerminalSettings: Codable, Equatable {
    var defaultShell: String = "/bin/zsh"
    var fontSize: Int = 14
    var cursorStyle: String = "bar"
}
```

With:

```swift
/// Terminal emulator appearance and behavior settings.
///
/// Note: the user-facing font size is expressed as `fontSizeOffset` — an
/// integer relative to a hidden base. The actual point size used by Ghostty
/// is computed at render time from the active display's PPI via
/// `AdaptiveFontSizeCalculator`. The legacy `fontSize` JSON key is migrated to
/// `fontSizeOffset` on first decode and never re-encoded.
struct TerminalSettings: Equatable {
    var defaultShell: String
    var fontSizeOffset: Int
    var cursorStyle: String

    init(
        defaultShell: String = "/bin/zsh",
        fontSizeOffset: Int = 0,
        cursorStyle: String = "bar"
    ) {
        self.defaultShell = defaultShell
        self.fontSizeOffset = TerminalSettings.clamp(fontSizeOffset)
        self.cursorStyle = cursorStyle
    }

    static func clamp(_ value: Int) -> Int {
        min(
            max(value, AdaptiveFontSizeCalculator.offsetRange.lowerBound),
            AdaptiveFontSizeCalculator.offsetRange.upperBound
        )
    }
}

extension TerminalSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case defaultShell
        case fontSizeOffset
        case cursorStyle
        case fontSize  // legacy, decode-only
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shell = try container.decodeIfPresent(String.self, forKey: .defaultShell) ?? "/bin/zsh"
        let cursor = try container.decodeIfPresent(String.self, forKey: .cursorStyle) ?? "bar"

        let offset: Int
        if let stored = try container.decodeIfPresent(Int.self, forKey: .fontSizeOffset) {
            offset = stored
        } else if let legacy = try container.decodeIfPresent(Int.self, forKey: .fontSize) {
            offset = legacy - 14
        } else {
            offset = 0
        }
        self.init(defaultShell: shell, fontSizeOffset: offset, cursorStyle: cursor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultShell, forKey: .defaultShell)
        try container.encode(fontSizeOffset, forKey: .fontSizeOffset)
        try container.encode(cursorStyle, forKey: .cursorStyle)
    }
}
```

**Step 4: Run tests; expect the new ones to pass and ensure old `PersistenceTests` still pass.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux test 2>&1 | tail -30
```

Expected: 8 new persistence tests pass. Build still compiles — but compile errors will now appear elsewhere because `terminal.fontSize` references are stale. Those are fixed in Tasks 3 and 4.

**Step 5: Commit (compiling-only-with-rest-of-stack, accept temporary breakage if any).**

If the project still compiles (because no other site references `terminal.fontSize` yet), commit normally. If not, fold this commit into Task 3 — but verify with:

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && grep -rn "terminal\.fontSize\b" Treemux/ --include="*.swift"
```

Expected hits: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift:1111` and `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift:66`. **Continue to Task 3 before committing** — these need to update together so the build stays green.

---

## Task 3: Update GhosttyKit consumers to use the calculator

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift` (lines 63–77)
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift` (line ~1111)

**Step 1: Drop `font-size` from the global Ghostty config.**

In `TreemuxGhosttyRuntime.swift`, replace the body of `writeTemporaryGhosttyConfig(for:)` (lines 63–77):

```swift
    /// Writes Treemux terminal settings as a temporary Ghostty config file.
    /// Caller must delete the returned URL after use.
    ///
    /// Note: `font-size` is intentionally omitted. Each surface picks its own
    /// `font_size` at creation and on every screen change, derived from the
    /// active display's PPI via `AdaptiveFontSizeCalculator`. Pushing a single
    /// global `font-size` would fight with the per-surface override.
    private func writeTemporaryGhosttyConfig(for terminal: TerminalSettings) -> URL? {
        let lines = [
            "cursor-style = \(terminal.cursorStyle)"
        ]
        let content = lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("treemux-ghostty-\(UUID().uuidString).conf")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
```

**Step 2: Update surface creation to use the calculator.**

In `TreemuxGhosttyController.swift`, find the line currently reading:

```swift
        configuration.font_size = Float(AppSettingsPersistence().load().terminal.fontSize)
```

(near line 1111, inside `withSurfaceConfig`). Replace with:

```swift
        let terminalSettings = AppSettingsPersistence().load().terminal
        let initialScreen = window?.screen ?? NSScreen.main
        configuration.font_size = Float(
            AdaptiveFontSizeCalculator.fontSize(
                for: initialScreen,
                offset: terminalSettings.fontSizeOffset
            )
        )
```

**Step 3: Build and run all tests.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux test 2>&1 | tail -30
```

Expected: build succeeds, all tests pass (Tasks 1+2's new tests included). `grep -rn "terminal\.fontSize\b"` should now return zero hits in `Treemux/`.

**Step 4: Commit (combined with Task 2 if it was deferred).**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/Domain/AppSettings.swift TreemuxTests/PersistenceTests.swift Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift && \
git commit -m "refactor: migrate terminal fontSize to fontSizeOffset, route via AdaptiveFontSizeCalculator"
```

---

## Task 4: `applyAdaptiveFontSize()` on the surface view

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift` (`TreemuxGhosttySurfaceView` class, around lines 463–620 and 1221)

**Background:** `TreemuxGhosttySurfaceView` already exposes `performBindingAction(_:)` at line 1221 which wraps `ghostty_surface_binding_action`. Ghostty understands `set_font_size:N` (where N is `f32`) — verified upstream in `src/input/Binding.zig`.

**Step 1: Add the method on `TreemuxGhosttySurfaceView`.**

Locate `func syncSurfaceMetrics()` (line 636). Immediately **after** the closing brace of that function, insert:

```swift
    /// Pushes the per-display font size to ghostty for this surface. Idempotent
    /// and cheap — safe to call from every screen / backing / settings change.
    func applyAdaptiveFontSize() {
        guard surface != nil else { return }
        let offset = AppSettingsPersistence().load().terminal.fontSizeOffset
        let screen = window?.screen ?? NSScreen.main
        let pt = AdaptiveFontSizeCalculator.fontSize(for: screen, offset: offset)
        _ = performBindingAction("set_font_size:\(pt)")
    }
```

**Step 2: Wire it into the existing lifecycle hooks.**

Modify the three existing overrides (lines 606–619). Final shape:

```swift
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSurfaceMetrics()
        applyAdaptiveFontSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncSurfaceMetrics()
        applyAdaptiveFontSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSurfaceMetrics()
        // No applyAdaptiveFontSize() here — frame changes are not screen
        // changes; calling per-frame would thrash ghostty unnecessarily.
    }
```

**Step 3: Build to verify.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

Expected: build succeeds (no test impact yet).

**Step 4: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift && \
git commit -m "feat: surface views push adaptive font size on lifecycle changes"
```

---

## Task 5: Cross-screen + settings-change observers

**Files:**
- Modify: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift` (`TreemuxGhosttySurfaceView`)

**Goal:** React to `NSWindow.didChangeScreenNotification` (window dragged across the screen boundary at the same backing scale) and to `treemuxTerminalSettingsDidChange` (user adjusted `fontSizeOffset`).

**Step 1: Add stored observer tokens.**

Find the property block of `TreemuxGhosttySurfaceView` (near line 463). Add:

```swift
    private var adaptiveFontObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
```

**Step 2: Add observer registration helper.**

Below `applyAdaptiveFontSize()` (added in Task 4), add:

```swift
    private func registerAdaptiveFontObservers() {
        // Tear down any prior registrations (window may change over view's lifetime).
        for token in adaptiveFontObservers {
            NotificationCenter.default.removeObserver(token)
        }
        adaptiveFontObservers.removeAll()

        // Per-window: window dragged to a different screen at the same backing scale.
        if let window {
            let screenToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAdaptiveFontSize() }
            }
            adaptiveFontObservers.append(screenToken)
            observedWindow = window
        }

        // Global: user changed fontSizeOffset (or any TerminalSettings field).
        let settingsToken = NotificationCenter.default.addObserver(
            forName: .treemuxTerminalSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAdaptiveFontSize() }
        }
        adaptiveFontObservers.append(settingsToken)
    }

    private func tearDownAdaptiveFontObservers() {
        for token in adaptiveFontObservers {
            NotificationCenter.default.removeObserver(token)
        }
        adaptiveFontObservers.removeAll()
        observedWindow = nil
    }
```

**Step 3: Hook registration into `viewDidMoveToWindow`.**

Update the override to:

```swift
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSurfaceMetrics()
        registerAdaptiveFontObservers()
        applyAdaptiveFontSize()
    }
```

**Step 4: Tear down on deinit.**

Find the existing `deinit` of `TreemuxGhosttySurfaceView`. If none, add at the end of the class:

```swift
    deinit {
        tearDownAdaptiveFontObservers()
    }
```

If a `deinit` already exists, add `tearDownAdaptiveFontObservers()` as its first line.

**Step 5: Build and confirm.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

Expected: clean build.

**Step 6: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift && \
git commit -m "feat: surface views react to screen drags and font offset changes"
```

---

## Task 6: Add 3 new `ShortcutAction` cases (with tests)

**Files:**
- Modify: `Treemux/Domain/ShortcutAction.swift`
- Create: `TreemuxTests/AdaptiveFontShortcutTests.swift`

**Step 1: Write failing tests asserting the three cases exist with correct defaults.**

Create `TreemuxTests/AdaptiveFontShortcutTests.swift`:

```swift
//
//  AdaptiveFontShortcutTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class AdaptiveFontShortcutTests: XCTestCase {

    func testIncreaseAction_defaultIsCmdEquals() {
        let shortcut = ShortcutAction.terminalFontSizeIncrease.defaultShortcut
        XCTAssertEqual(shortcut, StoredShortcut(key: "=", command: true, shift: false, option: false, control: false))
    }

    func testDecreaseAction_defaultIsCmdMinus() {
        let shortcut = ShortcutAction.terminalFontSizeDecrease.defaultShortcut
        XCTAssertEqual(shortcut, StoredShortcut(key: "-", command: true, shift: false, option: false, control: false))
    }

    func testResetAction_defaultIsCmdZero() {
        let shortcut = ShortcutAction.terminalFontSizeReset.defaultShortcut
        XCTAssertEqual(shortcut, StoredShortcut(key: "0", command: true, shift: false, option: false, control: false))
    }

    func testAllThreeActions_areInWindowCategory() {
        XCTAssertEqual(ShortcutAction.terminalFontSizeIncrease.category, .window)
        XCTAssertEqual(ShortcutAction.terminalFontSizeDecrease.category, .window)
        XCTAssertEqual(ShortcutAction.terminalFontSizeReset.category, .window)
    }

    func testAllThreeActions_haveTitles() {
        XCTAssertFalse(ShortcutAction.terminalFontSizeIncrease.title.isEmpty)
        XCTAssertFalse(ShortcutAction.terminalFontSizeDecrease.title.isEmpty)
        XCTAssertFalse(ShortcutAction.terminalFontSizeReset.title.isEmpty)
    }

    func testActions_areInAllCases() {
        XCTAssertTrue(ShortcutAction.allCases.contains(.terminalFontSizeIncrease))
        XCTAssertTrue(ShortcutAction.allCases.contains(.terminalFontSizeDecrease))
        XCTAssertTrue(ShortcutAction.allCases.contains(.terminalFontSizeReset))
    }
}
```

**Step 2: Run tests, verify they fail.**

Expected: compile error — cases unknown.

**Step 3: Add the three cases to `ShortcutAction`.**

Open `Treemux/Domain/ShortcutAction.swift`. After `case zoomPane` (line 44), append:

```swift
    case terminalFontSizeIncrease
    case terminalFontSizeDecrease
    case terminalFontSizeReset
```

In `category` (lines 48–58), extend the `.panes` arm to keep it compiling, then add a new arm. Final shape:

```swift
    var category: ShortcutCategory {
        switch self {
        case .openSettings, .commandPalette, .toggleSidebar, .openProject:
            return .general
        case .newTab, .closeTab, .nextTab, .previousTab:
            return .tabs
        case .splitHorizontal, .splitVertical, .closePane,
             .focusNextPane, .focusPreviousPane, .zoomPane:
            return .panes
        case .terminalFontSizeIncrease,
             .terminalFontSizeDecrease,
             .terminalFontSizeReset:
            return .window
        }
    }
```

In `title` (lines 60–77), append cases:

```swift
        case .terminalFontSizeIncrease: return "Increase Terminal Font Size"
        case .terminalFontSizeDecrease: return "Decrease Terminal Font Size"
        case .terminalFontSizeReset: return "Reset Terminal Font Size"
```

In `subtitle` (lines 79–96), append:

```swift
        case .terminalFontSizeIncrease: return "Make terminal text larger across all displays."
        case .terminalFontSizeDecrease: return "Make terminal text smaller across all displays."
        case .terminalFontSizeReset: return "Restore terminal font size to the default offset."
```

In `defaultShortcut` (lines 98–129), append before the closing brace:

```swift
        case .terminalFontSizeIncrease:
            return StoredShortcut(key: "=", command: true, shift: false, option: false, control: false)
        case .terminalFontSizeDecrease:
            return StoredShortcut(key: "-", command: true, shift: false, option: false, control: false)
        case .terminalFontSizeReset:
            return StoredShortcut(key: "0", command: true, shift: false, option: false, control: false)
```

**Step 4: Run all tests.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux test 2>&1 | tail -30
```

Expected: 6 new shortcut tests pass.

**Step 5: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/Domain/ShortcutAction.swift TreemuxTests/AdaptiveFontShortcutTests.swift && \
git commit -m "feat: add terminal font size shortcut actions"
```

---

## Task 7: Wire menu items + handlers in `AppDelegate`

**Files:**
- Modify: `Treemux/AppDelegate.swift`

**Step 1: Add three menu items under the View menu.**

Find the View menu construction in `buildMainMenu()` (lines 113–126). After the `commandPaletteItem` block, **before** the `viewMenuItem.submenu = viewMenu` line (line 124), insert:

```swift
        viewMenu.addItem(.separator())
        let fontIncreaseItem = NSMenuItem(title: "Increase Terminal Font Size", action: #selector(terminalFontSizeIncrease), keyEquivalent: "")
        fontIncreaseItem.target = self
        applyShortcut(.terminalFontSizeIncrease, to: fontIncreaseItem)
        viewMenu.addItem(fontIncreaseItem)
        let fontDecreaseItem = NSMenuItem(title: "Decrease Terminal Font Size", action: #selector(terminalFontSizeDecrease), keyEquivalent: "")
        fontDecreaseItem.target = self
        applyShortcut(.terminalFontSizeDecrease, to: fontDecreaseItem)
        viewMenu.addItem(fontDecreaseItem)
        let fontResetItem = NSMenuItem(title: "Reset Terminal Font Size", action: #selector(terminalFontSizeReset), keyEquivalent: "")
        fontResetItem.target = self
        applyShortcut(.terminalFontSizeReset, to: fontResetItem)
        viewMenu.addItem(fontResetItem)
```

**Step 2: Add the three `@objc` handlers near the other Menu Actions.**

Append after `previousTab()` (line 262), before the `// MARK: - Updates` block:

```swift
    @objc private func terminalFontSizeIncrease() {
        adjustTerminalFontSizeOffset(by: +1)
    }

    @objc private func terminalFontSizeDecrease() {
        adjustTerminalFontSizeOffset(by: -1)
    }

    @objc private func terminalFontSizeReset() {
        applyTerminalFontSizeOffset(0)
    }

    private func adjustTerminalFontSizeOffset(by delta: Int) {
        guard let store else { return }
        let next = store.settings.terminal.fontSizeOffset + delta
        applyTerminalFontSizeOffset(next)
    }

    private func applyTerminalFontSizeOffset(_ value: Int) {
        guard let store else { return }
        var draft = store.settings
        draft.terminal.fontSizeOffset = TerminalSettings.clamp(value)
        guard draft.terminal != store.settings.terminal else { return }
        store.updateSettings(draft)
    }
```

**Step 3: Build and verify.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

Expected: clean build. The hotkeys go through the standard menu key-equivalent path, and `WorkspaceStore.updateSettings` posts `treemuxTerminalSettingsDidChange`, which the surface views (Task 5) already pick up.

**Step 4: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/AppDelegate.swift && \
git commit -m "feat: View menu and Cmd-=/-/0 hotkeys for terminal font size"
```

---

## Task 8: Replace Settings UI Stepper with -/+/Reset block

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift` (`TerminalSettingsView`, lines 178–220)

**Step 1: Replace the entire `TerminalSettingsView` body.**

Replace lines 180–220 (`private struct TerminalSettingsView: View { ... }`) with:

```swift
private struct TerminalSettingsView: View {
    @Binding var settings: AppSettings

    private var offsetLabel: String {
        let offset = settings.terminal.fontSizeOffset
        return offset >= 0 ? "+\(offset)" : "\(offset)"
    }

    private var canDecrease: Bool {
        settings.terminal.fontSizeOffset > AdaptiveFontSizeCalculator.offsetRange.lowerBound
    }

    private var canIncrease: Bool {
        settings.terminal.fontSizeOffset < AdaptiveFontSizeCalculator.offsetRange.upperBound
    }

    private var currentDisplayPointSize: Int {
        AdaptiveFontSizeCalculator.fontSize(
            for: NSScreen.main,
            offset: settings.terminal.fontSizeOffset
        )
    }

    var body: some View {
        Form {
            TextField("Default Shell", text: $settings.terminal.defaultShell)

            Section {
                HStack(spacing: 8) {
                    Button {
                        settings.terminal.fontSizeOffset = TerminalSettings.clamp(settings.terminal.fontSizeOffset - 1)
                    } label: {
                        Label("Smaller", systemImage: "textformat.size.smaller")
                    }
                    .disabled(!canDecrease)

                    Text(offsetLabel)
                        .monospacedDigit()
                        .frame(minWidth: 32)
                        .multilineTextAlignment(.center)

                    Button {
                        settings.terminal.fontSizeOffset = TerminalSettings.clamp(settings.terminal.fontSizeOffset + 1)
                    } label: {
                        Label("Larger", systemImage: "textformat.size.larger")
                    }
                    .disabled(!canIncrease)

                    Spacer()

                    Button("Reset") {
                        settings.terminal.fontSizeOffset = 0
                    }
                    .disabled(settings.terminal.fontSizeOffset == 0)
                }
            } header: {
                Text("Terminal Font Size")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Currently \(currentDisplayPointSize) pt — auto-scaled for the active display.")
                    Text("The font size adjusts automatically per display so physical size stays consistent. Use ⌘= / ⌘- / ⌘0 to adjust quickly.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }

            Picker("Cursor Style", selection: $settings.terminal.cursorStyle) {
                Text("Block").tag("block")
                Text("Bar").tag("bar")
                Text("Underline").tag("underline")
            }
        }
        .formStyle(.grouped)
    }
}
```

**Step 2: Build and verify.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

Expected: clean build.

**Step 3: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/UI/Settings/SettingsSheet.swift && \
git commit -m "feat: replace font size stepper with offset buttons"
```

---

## Task 9: Add zh-Hans translations to `Localizable.xcstrings`

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Confirm which new strings need translations.**

The new user-visible strings are:
- `"Increase Terminal Font Size"` (menu / shortcut title)
- `"Decrease Terminal Font Size"` (menu / shortcut title)
- `"Reset Terminal Font Size"` (menu / shortcut title)
- `"Make terminal text larger across all displays."` (shortcut subtitle)
- `"Make terminal text smaller across all displays."` (shortcut subtitle)
- `"Restore terminal font size to the default offset."` (shortcut subtitle)
- `"Smaller"` (Settings button label) — may already exist; check
- `"Larger"` (Settings button label) — may already exist; check
- `"Reset"` (Settings button label) — may already exist; check
- `"Terminal Font Size"` (Settings section header) — may already exist; check
- `"Currently %lld pt — auto-scaled for the active display."` — interpolation
- `"The font size adjusts automatically per display so physical size stays consistent. Use ⌘= / ⌘- / ⌘0 to adjust quickly."`

Check existing entries:

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
for s in "Smaller" "Larger" "Reset" "Terminal Font Size"; do
  grep -c "\"$s\"" Treemux/Localizable.xcstrings && echo "  ^^ \"$s\""
done
```

Add only those keys that have count `0`.

**Step 2: Edit `Treemux/Localizable.xcstrings`.**

Open the JSON file. Inside the top-level `"strings": { ... }` object, add entries for each missing key in the same shape as existing entries:

```json
    "Increase Terminal Font Size" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "增大终端字号"
          }
        }
      }
    },
    "Decrease Terminal Font Size" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "减小终端字号"
          }
        }
      }
    },
    "Reset Terminal Font Size" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "重置终端字号"
          }
        }
      }
    },
    "Make terminal text larger across all displays." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "在所有显示器上放大终端文字。"
          }
        }
      }
    },
    "Make terminal text smaller across all displays." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "在所有显示器上缩小终端文字。"
          }
        }
      }
    },
    "Restore terminal font size to the default offset." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "将终端字号恢复为默认。"
          }
        }
      }
    },
    "Smaller" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "缩小"
          }
        }
      }
    },
    "Larger" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "放大"
          }
        }
      }
    },
    "Reset" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "重置"
          }
        }
      }
    },
    "Terminal Font Size" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "终端字号"
          }
        }
      }
    },
    "Currently %lld pt — auto-scaled for the active display." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "当前 %lld pt — 已根据当前显示器自动适配。"
          }
        }
      }
    },
    "The font size adjusts automatically per display so physical size stays consistent. Use ⌘= / ⌘- / ⌘0 to adjust quickly." : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "字号会按显示器密度自动调整，使物理大小一致。使用 ⌘= / ⌘- / ⌘0 可以快速微调。"
          }
        }
      }
    },
```

Add only the entries from this list that the grep in Step 1 reported as missing. **Skip any that already exist** to avoid JSON duplicate-key issues.

**Step 3: Validate JSON.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
python3 -c "import json; json.load(open('Treemux/Localizable.xcstrings'))" && echo "OK"
```

Expected: prints `OK`.

**Step 4: Build.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && xcodebuild -project Treemux.xcodeproj -scheme Treemux build 2>&1 | tail -10
```

Expected: clean build.

**Step 5: Commit.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
git add Treemux/Localizable.xcstrings && \
git commit -m "i18n: zh-Hans translations for adaptive terminal font UI"
```

---

## Task 10: Manual verification

**Step 1: Build the app.**

```bash
cd /Users/yanu/Documents/code/Terminal/treemux/.worktrees/feat+adaptive-terminal-font && \
xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug build 2>&1 | tail -5 && \
ls -la ~/Library/Developer/Xcode/DerivedData/ | grep -i treemux
```

Note the DerivedData hash. Tell the user (卡皮巴拉) to run:

```
rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<hash>/Build/Products/Debug/Treemux.app
```

(Per the project's CLAUDE.md instructions for launching the debug build.)

**Step 2: Verification checklist.** Ask the user to confirm each:

- [ ] Open Settings → Terminal: stepper is gone, replaced by Smaller / +0 / Larger / Reset row, with footer text "Currently N pt — auto-scaled for the active display."
- [ ] Click `Smaller` and `Larger`; the offset label updates and Save persists; text in open terminals reflows.
- [ ] In the View menu: Increase / Decrease / Reset Terminal Font Size items appear with `⌘=` / `⌘-` / `⌘0` indicators.
- [ ] Hit `⌘=` repeatedly with focus in any terminal; size grows step by step until disabled at offset +12.
- [ ] Hit `⌘0`; the offset returns to 0 and the displayed pt drops back to the auto-scaled value.
- [ ] Drag a window from the high-PPI display (e.g. MBP internal) to a lower-PPI external display and back; the visible glyph height stays approximately the same physically (text appears the same size in mm). Run `df` or some output beforehand to have something on screen to compare.
- [ ] Drag a window between two displays where backing scale is identical (both 2× Retina, different effective resolutions); confirm the font still adapts.
- [ ] Open a new tab, then a new split: each inherits the live offset and the active display's PPI.
- [ ] Verify migration: with a stale `~/.treemux-debug/settings.json` that contains `"fontSize": 18` (manually craft one if needed), launch the app — Settings should now show `+4` offset.
- [ ] Switch language to 中文: terminal menu items, settings labels, and footer text all appear in Chinese.

**Step 3: Roll up the verification commit.**

If any step required tweaks (e.g., a missing translation key, an off-by-one in clamp), fix and add to a separate commit. The verification itself does not need a commit.

---

## Out-of-Scope Reminders

The following were rejected during brainstorming — do not implement:

- Per-tab or per-window font offsets
- UI font scaling for sidebar/tabbar (SwiftUI Dynamic Type already handles chrome)
- A user-facing reference-PPI knob
- Settings UI for "use auto-scale on/off" — auto-scale is always on by design

## Plan Complete

Plan saved to `docs/plans/2026-04-28-adaptive-terminal-font-implementation.md`.
