# Feature 7 — Expand Terminal Font-Size Range + Slider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen the terminal font-size offset range from `-8 … +12` to `-8 … +36` and add a coarse-drag `Slider` to the settings UI while keeping the existing `±` fine-tune buttons.

**Architecture:** `AdaptiveFontSizeCalculator.offsetRange` is the single source of truth; every clamp / shortcut / button-enablement path derives from it, so widening the bound is a one-constant change plus test updates. The settings UI adds a `Slider` bound to `fontSizeOffset` through an `Int ↔ Double` computed binding, sitting above the unchanged button row.

**Tech Stack:** Swift, SwiftUI, XCTest. macOS app (Treemux).

## Global Constraints

- Communicate with the user in Chinese; code comments in English.
- All code changes happen in a git worktree under `.worktrees/<branch>/` (`/` → `+`); the main repo stays on `main`.
- Colors must use theme tokens — no hardcoded color values. (Slider uses system default tint; introduces no color.)
- User-visible strings use `LocalizedStringKey` + a `zh-Hans` entry in `Treemux/Localizable.xcstrings`. This feature adds **no** new user-visible strings, so no xcstrings change is expected.
- Only the upper bound changes (`+12` → `+36`); lower bound stays `-8`. The `6pt` floor and `72pt` ceiling in the point-size formula are unchanged.
- Build non-interactively with `-skipPackagePluginValidation` (SwiftLint plugin).

---

### Task 1: Widen `offsetRange` to `-8 … 36` (calculator + all affected tests)

**Files:**
- Modify: `Treemux/Domain/AdaptiveFontSizeCalculator.swift:23`
- Test: `TreemuxTests/AdaptiveFontSizeCalculatorTests.swift` (lines 42-46, 58-60, 90-92; add new cases)
- Test: `TreemuxTests/PersistenceTests.swift:200-204`

**Interfaces:**
- Consumes: nothing new.
- Produces: `AdaptiveFontSizeCalculator.offsetRange == -8 ... 36`. All downstream clamps (`clampOffset`, `TerminalSettings.clamp`, `AppDelegate` ⌘= shortcut, `SettingsSheet.canIncrease`) automatically honour the new upper bound `36`.

- [ ] **Step 1: Update the failing tests first (TDD — red)**

In `TreemuxTests/AdaptiveFontSizeCalculatorTests.swift`, change `testOffsetAbove_clampsToUpperBound` (currently lines 42-46) to:

```swift
    func testOffsetAbove_clampsToUpperBound() {
        let result = AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 99)
        // (14 + 36) × 1 = 50
        XCTAssertEqual(result, 50)
    }
```

Change `testClampOffset_above_returnsUpper` (currently lines 58-60) to:

```swift
    func testClampOffset_above_returnsUpper() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(100), 36)
    }
```

Rename and update `testOffsetRange_isMinus8To12` (currently lines 90-92) to:

```swift
    func testOffsetRange_isMinus8To36() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.offsetRange, -8 ... 36)
    }
```

Add these new cases immediately after `testClampOffset_below_returnsLower` (currently line 64):

```swift
    func testClampOffset_atUpperBound_returnsUpper() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(36), 36)
    }

    func testClampOffset_justAboveUpperBound_returnsUpper() {
        XCTAssertEqual(AdaptiveFontSizeCalculator.clampOffset(37), 36)
    }

    func testUpperBoundOffset_producesLargerPointSize() {
        // (14 + 36) × 109 / 109 = 50, below the 72pt ceiling
        XCTAssertEqual(AdaptiveFontSizeCalculator.fontSize(forPPI: 109, offset: 36), 50)
    }
```

In `TreemuxTests/PersistenceTests.swift`, change `testTerminalSettings_decodesLegacyFontSize_99_clampsToUpperBound` (currently lines 200-204) so the expectation on line 203 becomes:

```swift
        XCTAssertEqual(decoded.fontSizeOffset, 36)
```

Leave `testExtremeUpward_clampsTo72` (offset 12, still in range) and all lower-bound / floor tests unchanged.

- [ ] **Step 2: Run the updated tests to confirm they fail**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/AdaptiveFontSizeCalculatorTests \
  -only-testing:TreemuxTests/PersistenceTests/testTerminalSettings_decodesLegacyFontSize_99_clampsToUpperBound 2>&1 | tail -30
```
Expected: FAIL — assertions still see the old `-8 … 12` bound (e.g. `clampOffset(100)` returns `12`, not `36`).

- [ ] **Step 3: Widen the constant (green)**

In `Treemux/Domain/AdaptiveFontSizeCalculator.swift:23`, change:

```swift
    static let offsetRange: ClosedRange<Int> = -8 ... 12
```
to:
```swift
    static let offsetRange: ClosedRange<Int> = -8 ... 36
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run the same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/Domain/AdaptiveFontSizeCalculator.swift \
        TreemuxTests/AdaptiveFontSizeCalculatorTests.swift \
        TreemuxTests/PersistenceTests.swift
git commit -m "feat(settings): widen terminal font-size offset range to -8…+36"
```

---

### Task 2: Add coarse-drag `Slider` to the terminal font-size settings section

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift` (`TerminalSettingsView`, the "Terminal Font Size" `Section` at lines 252-289)

**Interfaces:**
- Consumes: `AdaptiveFontSizeCalculator.offsetRange` (now `-8 … 36`), `TerminalSettings.clamp(_:)`, existing `settings.terminal.fontSizeOffset` binding.
- Produces: no new public API. A `Slider` that reads/writes `fontSizeOffset` via an `Int ↔ Double` bridge, clamped through `TerminalSettings.clamp`.

- [ ] **Step 1: Add an `Int ↔ Double` binding helper to `TerminalSettingsView`**

Add this computed property to `TerminalSettingsView` (alongside `canDecrease` / `canIncrease`, near line 239):

```swift
    // Bridges the integer offset to Slider's Double API; the setter rounds and
    // clamps through the single source of truth so drags never escape the range.
    private var offsetSliderBinding: Binding<Double> {
        Binding(
            get: { Double(settings.terminal.fontSizeOffset) },
            set: { settings.terminal.fontSizeOffset = TerminalSettings.clamp(Int($0.rounded())) }
        )
    }
```

- [ ] **Step 2: Insert the `Slider` above the existing button row**

In `body`, inside the `Section` whose header is `Text("Terminal Font Size")`, place a `Slider` immediately before the existing `HStack(spacing: 8) { … }` (the `−` / value / `+` / Reset row starting at line 253). The `Section` content becomes:

```swift
            Section {
                Slider(
                    value: offsetSliderBinding,
                    in: Double(AdaptiveFontSizeCalculator.offsetRange.lowerBound)
                        ... Double(AdaptiveFontSizeCalculator.offsetRange.upperBound),
                    step: 1
                )

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
                    Text("Currently \(currentDisplayPointSize) pt on this display.")
                    Text("The font size adjusts automatically per display so physical size stays consistent. Use ⌘= / ⌘- / ⌘0 to adjust quickly.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
```

(Only the `Slider` line and its enclosing structure are new; the `HStack`, `header`, and `footer` are unchanged from the current code.)

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite (no regressions)**

Run:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation 2>&1 | tail -20
```
Expected: all tests pass (507+ green).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "feat(settings): add slider for terminal font size with fine-tune buttons"
```

---

## Manual Verification (final review / GUI smoke)

- Open Settings → Terminal. The "Terminal Font Size" section shows a slider above the `−`/value/`+`/Reset row.
- Drag the slider fully right → value reaches `+36`, footer shows a larger "N pt", terminal text visibly enlarges beyond the old `+12` maximum.
- Drag fully left → value reaches `-8`; `±` buttons still change by exactly 1.
- `⌘=` repeatedly → reaches `+36`; `⌘-` → reaches `-8`; `⌘0` → resets to `0`.
- Quit and relaunch → the chosen offset persists.
