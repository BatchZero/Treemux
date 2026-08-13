# Full-Screen Toolbar Transition Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the active Treemux theme before the native macOS full-screen animation begins so the toolbar never flashes white.

**Architecture:** Reuse `WindowContext.refreshFullScreenTitlebar()` as the only titlebar theme synchronization method. Add the AppKit pre-transition delegate callback and retain the existing post-transition callbacks as defensive synchronization after AppKit rebuilds the titlebar hierarchy.

**Tech Stack:** Swift, AppKit `NSWindowDelegate`, XCTest, Xcode/macOS UI verification.

## Global Constraints

- Keep the main repository directory on `main`; modify code only in the existing feature worktree.
- Preserve the native toolbar layout and system full-screen animation.
- Use the active theme token; do not hard-code a visible color.
- Use English for code comments.

---

### Task 1: Pre-transition titlebar synchronization

**Files:**
- Modify: `TreemuxTests/WindowManagerTests.swift`
- Modify: `Treemux/App/WindowContext.swift`

**Interfaces:**
- Consumes: `WindowContext.refreshFullScreenTitlebar()` and `themeManager.nsWindowBackgroundColor`.
- Produces: `WindowContext.windowWillEnterFullScreen(_:)` conforming to `NSWindowDelegate`.

- [ ] **Step 1: Write the failing regression test**

Add `testWillEnterFullScreenAppliesThemeBeforeAnimation()` that sets the real titlebar view layer to white, invokes `windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))`, and asserts that the layer immediately equals `context.themeManager.nsWindowBackgroundColor.cgColor`.

- [ ] **Step 2: Run the regression test and verify RED**

Run:

```bash
xcodebuild test -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:TreemuxTests/WindowManagerTests/testWillEnterFullScreenAppliesThemeBeforeAnimation
```

Expected: failure because `WindowContext` does not yet implement the pre-transition delegate callback.

- [ ] **Step 3: Add the minimal delegate callback**

Add:

```swift
func windowWillEnterFullScreen(_ notification: Notification) {
    refreshFullScreenTitlebar()
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the new test together with `testFullScreenAppliesThemeColorToTitlebarContainer` and `testMainWindowKeepsNativeToolbarLayout`. Expected: all pass.

- [ ] **Step 5: Verify the real transition**

Build a uniquely identified Debug app, launch it in the dark theme, enter true macOS full screen, and inspect the animation from its first frame through completion. Expected: the toolbar remains dark throughout, with the sidebar button, “Treemux” title, and trailing actions unchanged.

- [ ] **Step 6: Run final verification**

Run the complete test suite, `git diff --check`, and a standard Debug build. Expected: all tests and build succeed with no diff whitespace errors.

