# File Tree Scroll Memory & Settings Footer Buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remember the file tree's scroll position across tab switches, fix the misleading/unequal settings footer buttons, and retire the DESIGN.md governance constraint in CLAUDE.md.

**Architecture:** Scroll offset is cached as a plain (non-`@Published`) property on the persistent `FileBrowserTabController`; the `FileTreePanelView` `ScrollView` reads it via `onScrollGeometryChange` and restores it via a `ScrollPosition` binding on appear. The settings footer reuses one `UtilityButtonStyle` (extended with an optional accent fill and `@Environment(\.isEnabled)` dimming) for both Save and Cancel so they are equal-sized and the disabled state is visible.

**Tech Stack:** Swift, SwiftUI (macOS 15+ scroll APIs), XCTest.

## Global Constraints

- Any code change happens in the worktree `.worktrees/feat+scroll-memory-and-settings-buttons/` on branch `feat/scroll-memory-and-settings-buttons`. The main repo dir stays on `main`.
- Code comments in English; user-facing communication in Chinese.
- No new user-visible strings are introduced (Save/Cancel already localized in `Localizable.xcstrings`).
- Every visible colour must go through a theme token (`ThemeManager`); no hardcoded colours.
- Tests run via xcodebuild with `-skipPackagePluginValidation` (SwiftLint plugin requires it in non-interactive runs).
- Scroll memory is in-memory only — nothing is written to `FileBrowserTabState` / disk.

---

### Task 1: Add `treeScrollOffset` cache to `FileBrowserTabController`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileBrowserTabController.swift` (property declarations block, around lines 36-67)
- Test: `TreemuxTests/FileBrowserTabControllerTests.swift`

**Interfaces:**
- Consumes: existing `FileBrowserTabController(initial:dataSource:)` initializer.
- Produces: `var treeScrollOffset: CGFloat` on `FileBrowserTabController`, defaulting to `0`, readable and writable on the main actor.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/FileBrowserTabControllerTests.swift` (inside the existing `@MainActor final class`):

```swift
func test_treeScrollOffset_defaultsToZeroAndPersists() {
    let ctrl = FileBrowserTabController(
        initial: .init(rootPath: "/r", rootKind: .project),
        dataSource: GatedFileBrowserDataSource())
    XCTAssertEqual(ctrl.treeScrollOffset, 0)

    ctrl.treeScrollOffset = 142.5
    XCTAssertEqual(ctrl.treeScrollOffset, 142.5)
}
```

> If `GatedFileBrowserDataSource` is not visible from this file, use the same in-memory data source already imported by the test target's other `FileBrowserTabController` tests (e.g. the type used in `FileBrowserTabControllerStaleLoadTests.swift:18`).

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/test_treeScrollOffset_defaultsToZeroAndPersists`
Expected: FAIL — `value of type 'FileBrowserTabController' has no member 'treeScrollOffset'`.

- [ ] **Step 3: Add the property**

In `FileBrowserTabController.swift`, after the existing `@Published` state block (near line 67, after `truncatedDirs`), add:

```swift
    /// Last known vertical scroll offset of the file tree. Cached in-memory so
    /// the tree restores its position when the tab is re-mounted (e.g. after
    /// switching to a terminal tab and back). NOT @Published — it must not
    /// trigger a re-render, and it is intentionally never persisted to disk.
    var treeScrollOffset: CGFloat = 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/FileBrowserTabControllerTests/test_treeScrollOffset_defaultsToZeroAndPersists`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileBrowserTabController.swift TreemuxTests/FileBrowserTabControllerTests.swift
git commit -m "feat: cache file tree scroll offset on controller"
```

---

### Task 2: Restore scroll offset in `FileTreePanelView`

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileTreePanelView.swift:7-31` (the `FileTreePanelView` struct)

**Interfaces:**
- Consumes: `controller.treeScrollOffset` (read/write) from Task 1.
- Produces: no new public surface. UI-only behaviour change.

This task changes SwiftUI view code whose scroll behaviour cannot be exercised by a unit test; it is verified manually in the final task. Keep the change minimal and committed on its own so a reviewer can isolate it.

- [ ] **Step 1: Add a `ScrollPosition` state and wire the ScrollView**

In `FileTreePanelView`, add a state property and bind the existing `ScrollView`. Replace the struct body (lines 7-31) with:

```swift
struct FileTreePanelView: View {
    @ObservedObject var controller: FileBrowserTabController
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        VStack(spacing: 0) {
            FileTreeErrorBanner(controller: controller)
            FileTreeToolbar(controller: controller)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.rootChildren, id: \.id) { node in
                        NodeRow(node: node, depth: 0, density: store.settings.fileTree.density, controller: controller)
                    }
                    if controller.truncatedDirs.contains(controller.rootPath) {
                        LoadMoreRow(path: controller.rootPath, depth: 0, controller: controller)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollPosition($scrollPosition)
            // Persist the live offset so it survives a view rebuild (tab switch).
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                controller.treeScrollOffset = newValue
            }
            // Restore the cached offset when this view is (re-)mounted.
            .onAppear {
                scrollPosition.scrollTo(y: controller.treeScrollOffset)
            }
        }
        .background(theme.paneBackground)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED. (If `scrollPosition.scrollTo(y:)` is unavailable, fall back to `scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: controller.treeScrollOffset))` inside `.onAppear`.)

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/FileBrowser/FileTreePanelView.swift
git commit -m "feat: restore file tree scroll position across tab switches"
```

---

### Task 3: Extend `UtilityButtonStyle` with a filled variant and disabled dimming

**Files:**
- Modify: `Treemux/UI/Components/ButtonStyles.swift`
- Test: `TreemuxTests/ButtonStylesTests.swift`

**Interfaces:**
- Consumes: existing `DesignFonts.chromeBody`, `Radius.sm`, `Radius.pill`.
- Produces:
  - `UtilityButtonStyle` gains `var fill: Color? = nil` and `var onFill: Color = .white`. When `fill` is non-nil the button renders a filled background (using `fill`) with `onFill` text, at the same padding/radius as the bordered variant.
  - Both `UtilityButtonStyle` and `PillButtonStyle` dim to opacity `0.4` and skip the press scale when `@Environment(\.isEnabled)` is `false`.

- [ ] **Step 1: Write the failing test**

Add to `TreemuxTests/ButtonStylesTests.swift`:

```swift
func testUtilityFillDefaultsNil() {
    let style = UtilityButtonStyle(
        tint: Color(hex: "#C5C8C6"),
        activeTint: Color(hex: "#0066CC"),
        border: Color(hex: "#FFFFFF1A"))
    XCTAssertNil(style.fill)
}

func testUtilityStoresFillVariant() {
    let style = UtilityButtonStyle(
        tint: Color(hex: "#C5C8C6"),
        activeTint: Color(hex: "#0066CC"),
        border: Color(hex: "#FFFFFF1A"),
        fill: Color(hex: "#0066CC"),
        onFill: Color(hex: "#FFFFFF"))
    XCTAssertEqual(style.fill, Color(hex: "#0066CC"))
    XCTAssertEqual(style.onFill, Color(hex: "#FFFFFF"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/ButtonStylesTests`
Expected: FAIL — `extra arguments at positions ... 'fill', 'onFill'` / no member `fill`.

- [ ] **Step 3: Implement the style changes**

Replace the contents of `ButtonStyles.swift` (the two style structs) with:

```swift
/// Primary call-to-action: full-pill accent fill, press shrinks to 0.95.
/// Use ONLY for the single primary action in a dialog (Save/Open/Connect).
struct PillButtonStyle: ButtonStyle {
    let accent: Color
    let onAccent: Color

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(onAccent)
            .padding(.vertical, 11)
            .padding(.horizontal, 22)
            .background(accent, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Compact utility action: Radius.sm. Bordered by default; pass `fill` to render
/// an equal-sized filled primary (fill background + `onFill` text) so a primary
/// action can sit next to a Cancel at the same dimensions.
/// `isActive` (or press) lifts the bordered tint to `activeTint` (accent).
/// Disabled buttons dim to 0.4 and skip the press scale.
struct UtilityButtonStyle: ButtonStyle {
    let tint: Color
    let activeTint: Color
    let border: Color
    var isActive: Bool = false
    var fill: Color? = nil
    var onFill: Color = .white

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFonts.chromeBody)
            .foregroundStyle(foreground(isPressed: configuration.isPressed))
            .padding(.vertical, 8)
            .padding(.horizontal, 15)
            .background {
                if let fill {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(fill)
                } else {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .stroke(border, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private func foreground(isPressed: Bool) -> Color {
        if fill != nil { return onFill }
        return isActive || isPressed ? activeTint : tint
    }
}
```

> Keep the file's existing top comment block and `import SwiftUI` line intact above these structs.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/ButtonStylesTests`
Expected: PASS (all four tests, including the two pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Components/ButtonStyles.swift TreemuxTests/ButtonStylesTests.swift
git commit -m "feat: utility button filled variant and disabled dimming"
```

---

### Task 4: Make the settings footer Save/Cancel equal-sized

**Files:**
- Modify: `Treemux/UI/Settings/SettingsSheet.swift:101-124` (the footer `HStack`)

**Interfaces:**
- Consumes: `UtilityButtonStyle` filled variant from Task 3; `theme.textSecondary`, `theme.accentColor`, `theme.dividerColor`, `theme.onAccentColor`.
- Produces: no new public surface. UI-only change.

This task changes view code verified manually in Task 6; commit it on its own.

- [ ] **Step 1: Replace the footer buttons**

In `SettingsSheet.swift`, replace the footer `HStack` (lines 102-124, from `HStack {` through the closing `}` before `.frame(width: 640...)`) with:

```swift
                HStack {
                    Spacer()
                    Button("Cancel") {
                        // Revert theme if it was changed during preview
                        if draft.activeThemeID != originalSettings.activeThemeID {
                            theme.setActiveTheme(originalSettings.activeThemeID)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(UtilityButtonStyle(
                        tint: theme.textSecondary,
                        activeTint: theme.accentColor,
                        border: theme.dividerColor))

                    Button("Save") {
                        store.updateSettings(draft)
                        languageManager.apply(languageCode: draft.language)
                        dismiss()
                    }
                    .disabled(!hasChanges)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(UtilityButtonStyle(
                        tint: theme.textSecondary,
                        activeTint: theme.accentColor,
                        border: theme.dividerColor,
                        fill: theme.accentColor,
                        onFill: theme.onAccentColor))
                }
                .padding(Spacing.lg)
                .hairline(.top)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/Settings/SettingsSheet.swift
git commit -m "fix: equal-sized settings footer buttons with visible disabled state"
```

---

### Task 5: Retire DESIGN.md governance in CLAUDE.md

**Files:**
- Modify: `.claude/CLAUDE.md` (the `## UI 设计规范` section)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Rewrite the section**

Replace the entire `## UI 设计规范` section in `.claude/CLAUDE.md` (the four bullets) with:

```markdown
## UI 设计规范

- 颜色一律走主题 token（`~/.treemux/themes/*.yaml`，见 `Theme`/`ThemeLoader`/`ThemeManager`），禁止硬编码颜色。
- 主题同时驱动 App UI 与 Ghostty 终端配色；任何后续代码修改新增可见颜色，都必须接入主题 token，不得写死色值。
- 字体、间距、圆角等非颜色 token 固化在代码（如 `DesignFonts`/`Spacing`/`Radius`），不随主题变。
```

> This removes the bullet making `.claude/DESIGN.md` the sole basis for UI work and the derived "core principles" bullet, while keeping and strengthening the theme/YAML colour rule.

- [ ] **Step 2: Commit**

```bash
git add .claude/CLAUDE.md
git commit -m "docs: retire DESIGN.md governance, keep theme YAML colour rule"
```

---

### Task 6: Full build, test, and manual verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation`
Expected: all tests pass (previously 354+ tests; now includes the new scroll-offset and button tests).

- [ ] **Step 2: Build the Debug app and tell the user how to run it**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation`
Then report the exact run command to the user with the resolved DerivedData number, e.g.:
`rm -rf ~/.treemux-debug/ && open ~/Library/Developer/Xcode/DerivedData/Treemux-<编号>/Build/Products/Debug/Treemux.app`

- [ ] **Step 3: Manual verification checklist**

  1. Scroll the file tree down, switch to a terminal tab, switch back — the tree stays at the same scroll position.
  2. Open Settings without changing anything — Save appears greyed/disabled and clearly non-clickable; clicking does nothing.
  3. Change a setting — Save lights up to accent fill and saves on click.
  4. Save and Cancel are the same width and height.
