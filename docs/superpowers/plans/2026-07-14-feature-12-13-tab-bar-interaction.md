# Feature 12 + 13 — Tab-Bar Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both tab bars (`WorkspaceTabBarView`, `FileSubTabBarView`) use browser-style adaptive equal-width tabs with ellipsis truncation, and let a mouse scroll wheel scroll them horizontally while leaving trackpad scrolling native.

**Architecture:** A pure `TabBarLayout.uniformWidth(...)` computes each tab's width from the measured viewport width, tab count, and the bar's fixed chrome. A shared `ScrollWheelHorizontalRedirect` (`NSViewRepresentable` with a local scroll-wheel monitor) converts mouse-wheel vertical deltas into horizontal scroll via the macOS 15 `ScrollPosition` API. Each bar wires a `GeometryReader` for the viewport, `PreferenceKey`s for chrome/content width, applies the uniform width to every tab, and overlays the redirect.

**Tech Stack:** Swift, SwiftUI (macOS 15), AppKit (NSEvent monitor), XCTest.

## Global Constraints

- Communicate with the user in Chinese; code comments in English.
- All code changes happen in a git worktree under `.worktrees/<branch>/` (`/` → `+`); the main repo stays on `main`.
- Colors must use theme tokens — no hardcoded color values. The redirect overlay draws nothing (transparent, click-through).
- User-visible strings use `LocalizedStringKey` + a `zh-Hans` entry in `Treemux/Localizable.xcstrings`. This feature adds **no** new user-visible strings, so no xcstrings change is expected.
- Applies to BOTH bars: `WorkspaceTabBarView` and `FileSubTabBarView`.
- Tab sizing constants: `minTabWidth = 64`, `maxTabWidth = 240`.
- Deployment target macOS 15.0 — `ScrollPosition`, `.scrollPosition(_:)`, and `.onScrollGeometryChange(for:)` are available (already used in `FileTreePanelView`).
- Build/test non-interactively with `-skipPackagePluginValidation` (SwiftLint plugin).

---

### Task 1: `TabBarLayout` pure equal-width helper

**Files:**
- Create: `Treemux/UI/Workspace/TabBarLayout.swift`
- Test: `TreemuxTests/TreemuxTabLayoutTests.swift`

**Interfaces:**
- Produces: `enum TabBarLayout` with `static let minTabWidth: CGFloat = 64`, `static let maxTabWidth: CGFloat = 240`, and `static func uniformWidth(viewport: CGFloat, tabCount: Int, reservedChrome: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat`. Also three `PreferenceKey`s used by Tasks 3–4: `TabBarChromeWidthKey` (sum-reduce), `TabBarContentWidthKey` (max-reduce), and `TabBarViewportWidthKey` (max-reduce).

- [ ] **Step 1: Write the failing tests**

Create `TreemuxTests/TreemuxTabLayoutTests.swift`:

```swift
//
//  TreemuxTabLayoutTests.swift
//  TreemuxTests
//

import XCTest
@testable import Treemux

final class TreemuxTabLayoutTests: XCTestCase {
    // Few tabs: (viewport - chrome) / count exceeds max → capped at maxWidth.
    func testFewTabs_capsAtMaxWidth() {
        let w = TabBarLayout.uniformWidth(
            viewport: 1000, tabCount: 2, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 240)
    }

    // Medium: result lands strictly inside [min, max] and equals the exact share.
    func testMediumTabs_returnsExactShare() {
        // (700 - 40) / 6 = 110
        let w = TabBarLayout.uniformWidth(
            viewport: 700, tabCount: 6, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 110)
    }

    // Many tabs: share drops below min → floored at minWidth (overflow → scroll).
    func testManyTabs_floorsAtMinWidth() {
        // (600 - 40) / 20 = 28 → clamps up to 64
        let w = TabBarLayout.uniformWidth(
            viewport: 600, tabCount: 20, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 64)
    }

    // Zero tabs: no division by zero, returns maxWidth.
    func testZeroTabs_returnsMaxWidth() {
        let w = TabBarLayout.uniformWidth(
            viewport: 800, tabCount: 0, reservedChrome: 40, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 240)
    }

    // Chrome wider than viewport: negative usable → clamps up to minWidth.
    func testChromeExceedsViewport_clampsToMinWidth() {
        let w = TabBarLayout.uniformWidth(
            viewport: 30, tabCount: 3, reservedChrome: 100, minWidth: 64, maxWidth: 240)
        XCTAssertEqual(w, 64)
    }

    func testConstants() {
        XCTAssertEqual(TabBarLayout.minTabWidth, 64)
        XCTAssertEqual(TabBarLayout.maxTabWidth, 240)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd .worktrees/feat+feature-12-13-tab-bar-interaction
xcodebuild test -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation \
  -only-testing:TreemuxTests/TreemuxTabLayoutTests 2>&1 | tail -20
```
Expected: FAIL — `TabBarLayout` does not exist yet (compile error / unresolved identifier).

- [ ] **Step 3: Create the implementation**

Create `Treemux/UI/Workspace/TabBarLayout.swift`:

```swift
//
//  TabBarLayout.swift
//  Treemux
//

import SwiftUI

/// Browser-style equal-width tab sizing and the measurement preference keys the
/// tab bars use to feed it. Pure so the width math is unit-testable.
enum TabBarLayout {
    /// Smallest a tab may shrink to before the bar overflows into horizontal scroll.
    static let minTabWidth: CGFloat = 64
    /// Largest a tab grows to when there is spare room (Chrome-style cap).
    static let maxTabWidth: CGFloat = 240

    /// The width every tab in a bar should take so `tabCount` tabs divide the
    /// space left after the bar's fixed chrome, clamped to a readable range.
    /// `tabCount == 0` returns `maxWidth` (no division); a negative usable width
    /// clamps up to `minWidth`.
    static func uniformWidth(
        viewport: CGFloat,
        tabCount: Int,
        reservedChrome: CGFloat,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        guard tabCount > 0 else { return maxWidth }
        let usable = viewport - reservedChrome
        let raw = usable / CGFloat(tabCount)
        return min(max(raw, minWidth), maxWidth)
    }
}

/// Sums the widths of a bar's fixed chrome elements (group eyebrows, dividers)
/// so tabs can divide only the remaining space.
struct TabBarChromeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// Reports the natural width of a bar's tab content (the inner HStack) so the
/// bar can compute how far it can scroll horizontally.
struct TabBarContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the scroll viewport width of a tab bar.
struct TabBarViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same command as Step 2.
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/Workspace/TabBarLayout.swift TreemuxTests/TreemuxTabLayoutTests.swift
git commit -m "feat(tabs): add TabBarLayout equal-width helper + measurement keys"
```

---

### Task 2: `ScrollWheelHorizontalRedirect` shared component

**Files:**
- Create: `Treemux/UI/Components/ScrollWheelHorizontalRedirect.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct ScrollWheelHorizontalRedirect: NSViewRepresentable` with a single stored closure `let onWheel: (CGFloat) -> Void`. It is used as a transparent, click-through overlay over a tab bar. It calls `onWheel(deltaY)` only for **mouse-wheel** (non-precise) vertical scroll events whose pointer is inside the overlay's bounds; trackpad (`hasPreciseScrollingDeltas`) events are passed through untouched. Tasks 3–4 place it via `.overlay(ScrollWheelHorizontalRedirect { delta in ... })`.

- [ ] **Step 1: Create the component**

Create `Treemux/UI/Components/ScrollWheelHorizontalRedirect.swift`:

```swift
//
//  ScrollWheelHorizontalRedirect.swift
//  Treemux
//

import SwiftUI
import AppKit

/// Transparent, click-through overlay that redirects a plain mouse scroll
/// wheel (vertical) into a horizontal-scroll callback, while leaving trackpad
/// gestures (`hasPreciseScrollingDeltas`) to the native ScrollView. Intended to
/// sit as an `.overlay` covering a horizontal tab bar.
struct ScrollWheelHorizontalRedirect: NSViewRepresentable {
    /// Vertical wheel delta (`event.scrollingDeltaY`) for a mouse wheel fired
    /// over this overlay. Receiver maps it to a horizontal scroll offset.
    let onWheel: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelMonitorView {
        WheelMonitorView(onWheel: onWheel)
    }

    func updateNSView(_ nsView: WheelMonitorView, context: Context) {
        nsView.onWheel = onWheel
    }

    /// Click-through NSView that observes scroll-wheel events through a local
    /// monitor. Using a monitor (not an overridden `scrollWheel`) keeps the
    /// view transparent to the tabs beneath it.
    final class WheelMonitorView: NSView {
        var onWheel: (CGFloat) -> Void
        private var monitor: Any?

        init(onWheel: @escaping (CGFloat) -> Void) {
            self.onWheel = onWheel
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Click-through: never become the hit-test target so clicks/drags reach
        // the tabs below. The scroll monitor works independently of hit-testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                installMonitor()
            }
        }

        private func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // Trackpad → leave to native horizontal scrolling.
                if event.hasPreciseScrollingDeltas { return event }
                // Only redirect a vertical-dominant wheel that is over this bar.
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
                self.onWheel(event.scrollingDeltaY)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
cd .worktrees/feat+feature-12-13-tab-bar-interaction
xcodebuild build -project Treemux.xcodeproj -scheme Treemux \
  -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Treemux/UI/Components/ScrollWheelHorizontalRedirect.swift
git commit -m "feat(tabs): add ScrollWheelHorizontalRedirect wheel->horizontal overlay"
```

---

### Task 3: Wire `WorkspaceTabBarView` (equal width + wheel + remove TreemuxTabSizing)

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`
- Delete: `TreemuxTests/TreemuxTabSizingTests.swift`

**Interfaces:**
- Consumes: `TabBarLayout.uniformWidth`, `TabBarLayout.minTabWidth/maxTabWidth`, `TabBarChromeWidthKey`, `TabBarContentWidthKey` (Task 1); `ScrollWheelHorizontalRedirect` (Task 2).
- Produces: no new public API. Removes `enum TreemuxTabSizing`.

- [ ] **Step 1: Add measurement + scroll state and rebuild `body`**

In `WorkspaceTabBarView`, add these `@State` properties next to the existing ones (after `@State private var draggedTabID: UUID?`):

```swift
    @State private var viewportWidth: CGFloat = 0
    @State private var chromeWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var liveScrollX: CGFloat = 0
```

Add a computed uniform width, placed after the `groups` computed property:

```swift
    private var tabCount: Int { groups.files.count + groups.shell.count }

    private var uniformTabWidth: CGFloat {
        TabBarLayout.uniformWidth(
            viewport: viewportWidth,
            tabCount: tabCount,
            reservedChrome: chromeWidth + Spacing.xs * 2,
            minWidth: TabBarLayout.minTabWidth,
            maxWidth: TabBarLayout.maxTabWidth
        )
    }

    private var maxScrollX: CGFloat { max(0, contentWidth - viewportWidth) }
```

Replace the `body` (lines ~21-64) with the version below. Changes vs. the current code: the `ScrollView` is wrapped so `viewportWidth` is measured; the inner `HStack` reports its width via `TabBarContentWidthKey`; each eyebrow and the divider report their width via `TabBarChromeWidthKey`; `.scrollPosition`, `.onScrollGeometryChange`, and the wheel overlay are attached. The `+` button and outer chrome are unchanged.

```swift
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    if !groups.files.isEmpty {
                        TabGroupEyebrow(title: "Files", color: theme.accentColor)
                            .background(chromeWidthReporter)
                        ForEach(groups.files) { tab in tabView(tab) }
                    }
                    if !groups.files.isEmpty && !groups.shell.isEmpty {
                        Rectangle()
                            .fill(theme.dividerColor)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, Spacing.xxs)
                            .background(chromeWidthReporter)
                    }
                    if !groups.shell.isEmpty {
                        TabGroupEyebrow(title: "Shell", color: theme.accentColor)
                            .background(chromeWidthReporter)
                        ForEach(groups.shell) { tab in tabView(tab) }
                    }
                }
                .padding(.horizontal, Spacing.xs)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: TabBarContentWidthKey.self, value: g.size.width)
                    }
                )
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                liveScrollX = x
            }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TabBarViewportWidthKey.self, value: g.size.width)
                }
            )
            .onPreferenceChange(TabBarViewportWidthKey.self) { viewportWidth = $0 }
            .onPreferenceChange(TabBarContentWidthKey.self) { contentWidth = $0 }
            .onPreferenceChange(TabBarChromeWidthKey.self) { chromeWidth = $0 }
            .overlay(
                ScrollWheelHorizontalRedirect { deltaY in
                    // Wheel down scrolls toward the trailing edge. Sign/step
                    // calibrated during GUI smoke; flip the sign if inverted.
                    let target = min(max(liveScrollX - deltaY * 3, 0), maxScrollX)
                    scrollPosition.scrollTo(x: target)
                }
            )

            // New tab button
            Button {
                workspace.createTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.trailing, Spacing.xs)
        }
        .frame(height: 38)
        .background(theme.tabBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)
        }
    }

    // Reports a chrome element's width into TabBarChromeWidthKey (summed).
    private var chromeWidthReporter: some View {
        GeometryReader { g in
            Color.clear.preference(key: TabBarChromeWidthKey.self, value: g.size.width)
        }
    }
```

(`TabBarViewportWidthKey`, `TabBarContentWidthKey`, and `TabBarChromeWidthKey` are all declared in `TabBarLayout.swift` from Task 1 — do not redeclare them here.)

- [ ] **Step 2: Apply the uniform width to the tabs and rename field, remove TreemuxTabSizing**

At the rename field (currently line ~79), change:
```swift
            .frame(width: TreemuxTabSizing.width(for: renameText.isEmpty ? "Tab name" : renameText, paneCount: paneCount(for: tab)))
```
to:
```swift
            .frame(width: uniformTabWidth)
```

At the tab button (currently line ~198), change:
```swift
        .frame(width: TreemuxTabSizing.width(for: tab.title, paneCount: paneCount, hasDot: dotKind != nil))
```
to:
```swift
        .frame(width: width)
```
and add a `width` parameter to `TabButton` (it is a nested `private struct`): add `let width: CGFloat` to its stored properties, use `.frame(width: width)`, and pass `width: uniformTabWidth` where `TabButton(...)` is constructed inside `tabView(_:)`. (Find the `TabButton(` call site in `tabView` and add `width: uniformTabWidth` to its arguments.)

Delete the entire `enum TreemuxTabSizing { ... }` block (currently lines ~262-282, including the `// MARK: - Tab Sizing` comment).

Delete the test file:
```bash
git rm TreemuxTests/TreemuxTabSizingTests.swift
```

- [ ] **Step 3: Build, then run the full suite**

Run:
```bash
cd .worktrees/feat+feature-12-13-tab-bar-interaction
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors (e.g. the `TabButton` call site) until it builds.

Then:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: all tests pass (the `TreemuxTabSizingTests` are gone; `TreemuxTabLayoutTests` from Task 1 pass).

- [ ] **Step 4: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift TreemuxTests/TreemuxTabSizingTests.swift
git commit -m "feat(tabs): browser-style equal width + wheel scroll for workspace tab bar"
```

---

### Task 4: Wire `FileSubTabBarView` (equal width + truncation + wheel)

**Files:**
- Modify: `Treemux/UI/FileBrowser/FileSubTabBarView.swift`

**Interfaces:**
- Consumes: `TabBarLayout`, `TabBarContentWidthKey`, `TabBarViewportWidthKey`, `ScrollWheelHorizontalRedirect` (Tasks 1–3). This bar has no group eyebrows, so `reservedChrome` is just the inner `HStack` padding (no `TabBarChromeWidthKey`).

- [ ] **Step 1: Add measurement + scroll state and computed width**

In `FileSubTabBarView`, add `@State` next to the existing `hoveredID`/`draggedID`:

```swift
    @State private var viewportWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()
    @State private var liveScrollX: CGFloat = 0
```

Add computed helpers after `body` (or before it):

```swift
    private var uniformTabWidth: CGFloat {
        TabBarLayout.uniformWidth(
            viewport: viewportWidth,
            tabCount: controller.subTabs.count,
            reservedChrome: Spacing.xs * 2,
            minWidth: TabBarLayout.minTabWidth,
            maxWidth: TabBarLayout.maxTabWidth
        )
    }

    private var maxScrollX: CGFloat { max(0, contentWidth - viewportWidth) }
```

- [ ] **Step 2: Rebuild `body` with measurement, scroll wiring, and the wheel overlay**

Replace the `body` (lines ~18-52) with:

```swift
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(controller.subTabs) { tab in
                    SubTabButton(
                        tab: tab,
                        isActive: tab.id == controller.activeSubTabID,
                        isHovered: hoveredID == tab.id,
                        isDirty: dirtyState(for: tab),
                        rootPath: controller.rootPath,
                        width: uniformTabWidth,
                        onSelect: { controller.activateSubTab(tab.id) },
                        onClose: { controller.closeSubTab(tab.id) },
                        onCopyAbsolute: { controller.copyPath(tab.path, mode: .absolute) },
                        onCopyRelative: { controller.copyPath(tab.path, mode: .relative) },
                        onPin: { controller.pinActiveSubTab() },
                        onCloseOthers: { closeAllExcept(tab.id) },
                        onCloseAll: { closeAll() }
                    )
                    .onHover { hoveredID = $0 ? tab.id : nil }
                    .onDrag {
                        draggedID = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: SubTabDropDelegate(
                        targetID: tab.id,
                        controller: controller,
                        draggedID: $draggedID
                    ))
                }
            }
            .padding(.horizontal, Spacing.xs)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TabBarContentWidthKey.self, value: g.size.width)
                }
            )
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            liveScrollX = x
        }
        .background(
            GeometryReader { g in
                Color.clear.preference(key: TabBarViewportWidthKey.self, value: g.size.width)
            }
        )
        .onPreferenceChange(TabBarViewportWidthKey.self) { viewportWidth = $0 }
        .onPreferenceChange(TabBarContentWidthKey.self) { contentWidth = $0 }
        .overlay(
            ScrollWheelHorizontalRedirect { deltaY in
                let target = min(max(liveScrollX - deltaY * 3, 0), maxScrollX)
                scrollPosition.scrollTo(x: target)
            }
        )
        .frame(height: 32)
        .background(theme.tabBarBackground)
    }
```

- [ ] **Step 3: Add `width` to `SubTabButton` and truncate the title**

In `SubTabButton`, add a stored property `let width: CGFloat` (place it after `let rootPath: String`).

Change the title `Text` (currently lines ~122-125) from:
```swift
                Text(URL(fileURLWithPath: tab.path).lastPathComponent)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .italic(!tab.isPinned)
                    .foregroundStyle(isActive ? .primary : .secondary)
```
to:
```swift
                Text(URL(fileURLWithPath: tab.path).lastPathComponent)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .italic(!tab.isPinned)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
```

Apply the fixed width to the button. At the end of the `Button`'s content (after the outer `.padding(.horizontal, Spacing.xs)` on the inner `HStack`, i.e. on the button label just before `.background(...)`), the simplest reliable placement is to add `.frame(width: width)` to the `Button` itself — add it right after `.buttonStyle(.plain)` on the `SubTabButton` body:

```swift
        .buttonStyle(.plain)
        .frame(width: width)
        .contextMenu {
```

(Confirm during build that truncation + fixed width render correctly; the `maxWidth: .infinity` title inside a `width`-bounded button truncates with an ellipsis, matching the workspace tab bar.)

- [ ] **Step 4: Build, then run the full suite**

Run:
```bash
cd .worktrees/feat+feature-12-13-tab-bar-interaction
xcodebuild build -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. Fix compile errors until it builds.

Then:
```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -skipPackagePluginValidation 2>&1 | tail -15
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Treemux/UI/FileBrowser/FileSubTabBarView.swift
git commit -m "feat(tabs): browser-style equal width + wheel scroll for file sub-tab bar"
```

---

## Manual Verification (final review / GUI smoke)

- Open a workspace with several tabs: tabs are equal width; open many → they
  shrink together to the floor, then the bar scrolls horizontally.
- Open a file tab with several sub-tabs (open multiple files): sub-tabs are
  equal width; long filenames show a trailing ellipsis.
- Mouse scroll wheel (vertical) over each bar scrolls it horizontally in the
  natural direction. If inverted, flip the `deltaY` sign in the overlay
  closures (both bars) and rebuild.
- Trackpad two-finger horizontal swipe still scrolls both bars natively.
- No regressions: drag-to-reorder, tab rename (workspace), close button,
  right-click context menus, "+" new-tab button, sub-tab pin/close-others/
  close-all.
