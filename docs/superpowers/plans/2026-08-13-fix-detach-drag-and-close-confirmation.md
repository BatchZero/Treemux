# Detach Drag and Main-Window Close Confirmation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make real sidebar drag tear-off create a child window and require confirmation before closing a main window that still owns detached children.

**Architecture:** Correct the callback at the AppKit delegate boundary and extract its geometry decision into a small pure function. Route main-window close permission through `NSWindowDelegate` on `WindowContext`, with `WindowManager` owning a testable confirmation policy and the existing `willClose` cascade remaining responsible for teardown.

**Tech Stack:** Swift 6, AppKit (`NSOutlineViewDelegate`, `NSWindowDelegate`, `NSAlert`), SwiftUI hosting, XCTest, String Catalog localization.

## Global Constraints

- Work only in `.worktrees/feat+detach-to-new-window`; the main repository stays on `main`.
- Code comments are English; user-facing strings are localized for English and `zh-Hans`.
- Keep existing sidebar reorder behavior and detached-window persistence behavior unchanged.
- Use `NSWindow(contentViewController: NSHostingController(...))`; do not introduce a manual toolbar.
- Add no hard-coded colors or new dependencies.

---

### Task 1: Correct the outline-view drag completion boundary

**Files:**
- Modify: `Treemux/UI/Sidebar/SidebarCoordinator.swift:912-952`
- Test: `TreemuxTests/DetachPasteboardItemTests.swift:18-35`

**Interfaces:**
- Consumes: the existing `DetachPasteboardItem.detachType` payload and `onDetachNode: ((DetachedNodeRef) -> Void)?` callback.
- Produces: `SidebarCoordinator.shouldDetachDrag(operation:releasePoint:outlineRectInScreen:) -> Bool` and the Objective-C selector `outlineView:draggingSession:endedAtPoint:operation:`.

- [ ] **Step 1: Write failing selector and drag-decision tests**

Replace the mistaken selector assertion and add decision cases:

```swift
@MainActor
func testSidebarCoordinatorImplementsOutlineViewDragEndedDelegateCallback() {
    let coordinator = SidebarCoordinator()
    XCTAssertTrue(coordinator.responds(to: NSSelectorFromString(
        "outlineView:draggingSession:endedAtPoint:operation:"
    )))
}

func testDragOutsideOutlineWithNoCompletedOperationDetaches() {
    XCTAssertTrue(SidebarCoordinator.shouldDetachDrag(
        operation: [],
        releasePoint: NSPoint(x: 500, y: 200),
        outlineRectInScreen: NSRect(x: 0, y: 0, width: 250, height: 600)
    ))
}

func testCompletedReorderOrReleaseInsideOutlineDoesNotDetach() {
    let rect = NSRect(x: 0, y: 0, width: 250, height: 600)
    XCTAssertFalse(SidebarCoordinator.shouldDetachDrag(
        operation: .move,
        releasePoint: NSPoint(x: 500, y: 200),
        outlineRectInScreen: rect
    ))
    XCTAssertFalse(SidebarCoordinator.shouldDetachDrag(
        operation: [],
        releasePoint: NSPoint(x: 100, y: 200),
        outlineRectInScreen: rect
    ))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -quiet -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:TreemuxTests/DetachPasteboardItemTests
```

Expected: FAIL because the live outline-view selector and `shouldDetachDrag` do not exist.

- [ ] **Step 3: Implement the minimal callback correction**

Use the exact outline delegate signature and centralize the decision:

```swift
static func shouldDetachDrag(
    operation: NSDragOperation,
    releasePoint: NSPoint,
    outlineRectInScreen: NSRect
) -> Bool {
    operation == [] && !outlineRectInScreen.contains(releasePoint)
}

@objc(outlineView:draggingSession:endedAtPoint:operation:)
func outlineView(
    _ outlineView: NSOutlineView,
    draggingSession session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
) {
    guard outlineView === container?.outlineView,
          let window = outlineView.window else { return }
    let rect = window.convertToScreen(outlineView.convert(outlineView.bounds, to: nil))
    guard Self.shouldDetachDrag(
        operation: operation,
        releasePoint: screenPoint,
        outlineRectInScreen: rect
    ) else { return }
    // Decode the existing detach payload and invoke onDetachNode.
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Task 1 command again. Expected: PASS.

- [ ] **Step 5: Commit the drag boundary fix**

```bash
git add Treemux/UI/Sidebar/SidebarCoordinator.swift \
  TreemuxTests/DetachPasteboardItemTests.swift
git commit -m "fix(detach): handle outline drag completion"
```

---

### Task 2: Add a cancellable main-window close policy

**Files:**
- Modify: `Treemux/App/WindowManager.swift:18-190`
- Modify: `Treemux/App/WindowContext.swift:14-150`
- Test: `TreemuxTests/WindowManagerTests.swift`

**Interfaces:**
- Consumes: `WindowManager.childContexts`, `WindowContext.kind`, and the current main-window `willClose` cascade.
- Produces: `WindowManager.shouldCloseMainWindow() -> Bool`, injectable `mainWindowCloseConfirmation: (Int) -> Bool`, and `WindowContext.windowShouldClose(_:) -> Bool`.

- [ ] **Step 1: Write failing close-policy tests**

Add tests proving the prompt is skipped with no children and that cancel/confirm decisions preserve state before the close notification:

```swift
func testMainWindowCloseWithoutChildrenDoesNotPrompt() {
    let mgr = WindowManager(store: makeStore(), mainWindowCloseConfirmation: { _ in
        XCTFail("confirmation must not run without children")
        return false
    })
    XCTAssertTrue(mgr.shouldCloseMainWindow())
}

func testMainWindowCloseWithChildCanBeCancelledWithoutChangingState() {
    let store = makeStoreWithWorkspace()
    let mgr = WindowManager(store: store, mainWindowCloseConfirmation: { count in
        XCTAssertEqual(count, 1)
        return false
    })
    let ref = DetachedNodeRef.workspace(store.workspaces[0].id)
    mgr.detach(ref)

    XCTAssertFalse(mgr.shouldCloseMainWindow())
    XCTAssertEqual(mgr.childContexts.count, 1)
    XCTAssertTrue(store.isDetached(ref))
}

func testMainWindowCloseWithChildCanBeConfirmed() {
    let store = makeStoreWithWorkspace()
    let mgr = WindowManager(store: store, mainWindowCloseConfirmation: { _ in true })
    mgr.detach(.workspace(store.workspaces[0].id))
    XCTAssertTrue(mgr.shouldCloseMainWindow())
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -quiet -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -only-testing:TreemuxTests/WindowManagerTests
```

Expected: FAIL because the injectable policy and `shouldCloseMainWindow()` are missing.

- [ ] **Step 3: Implement the testable confirmation policy**

Add an ignored closure property and initializer parameter:

```swift
@ObservationIgnored
private let mainWindowCloseConfirmation: (Int) -> Bool

init(
    store: WorkspaceStore,
    mainWindowCloseConfirmation: @escaping (Int) -> Bool = WindowManager.presentMainWindowCloseConfirmation
) {
    self.store = store
    self.mainWindowCloseConfirmation = mainWindowCloseConfirmation
}

func shouldCloseMainWindow() -> Bool {
    guard !childContexts.isEmpty else { return true }
    return mainWindowCloseConfirmation(childContexts.count)
}
```

The default presenter uses `NSAlert`, makes **Cancel** the Return-key action,
and marks **Close All Windows** destructive.

- [ ] **Step 4: Route `NSWindowDelegate` through `WindowContext`**

Make `WindowContext` inherit `NSObject` and conform to `NSWindowDelegate`, call
`super.init()` after stored properties are initialized, assign
`window.delegate = self`, and implement:

```swift
func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard case .main = kind else { return true }
    return windowManager?.shouldCloseMainWindow() ?? true
}
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run the Task 2 command again. Expected: PASS.

- [ ] **Step 6: Commit the close policy**

```bash
git add Treemux/App/WindowManager.swift Treemux/App/WindowContext.swift \
  TreemuxTests/WindowManagerTests.swift
git commit -m "feat(window): confirm closing detached children"
```

---

### Task 3: Restore detached children after a cancelled termination

**Files:**
- Modify: `Treemux/App/WindowManager.swift:171-188`
- Test: `TreemuxTests/WindowManagerTests.swift`

**Interfaces:**
- Consumes: persisted `WorkspaceStore.detachedNodes`, `launchMain()`, and `restoreChildWindows()`.
- Produces: `recoverMainWindowIfCancelled()` restoring the complete pre-quit window set.

- [ ] **Step 1: Write the failing recovery test**

```swift
func testRecoverAfterCancelledTerminationRestoresMainAndDetachedWindows() {
    let store = makeStoreWithWorkspace()
    let ref = DetachedNodeRef.workspace(store.workspaces[0].id)
    store.detachedNodes.insert(ref)
    let mgr = WindowManager(store: store)

    mgr.recoverMainWindowIfCancelled()

    XCTAssertNotNil(mgr.mainWindowContext)
    XCTAssertEqual(mgr.childContexts.count, 1)
    XCTAssertTrue(store.isDetached(ref))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run the Task 2 command. Expected: FAIL because recovery currently launches only the main window.

- [ ] **Step 3: Restore persisted children after the main window**

```swift
func recoverMainWindowIfCancelled() {
    guard mainWindowContext == nil, childContexts.isEmpty else { return }
    launchMain()
    restoreChildWindows()
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Task 2 command again. Expected: PASS.

- [ ] **Step 5: Commit recovery behavior**

```bash
git add Treemux/App/WindowManager.swift TreemuxTests/WindowManagerTests.swift
git commit -m "fix(window): restore children after cancelled quit"
```

---

### Task 4: Localize, verify, and interactively test

**Files:**
- Modify: `Treemux/Localizable.xcstrings`
- Test: `TreemuxTests/WindowManagerTests.swift`

**Interfaces:**
- Consumes: alert keys from Task 2.
- Produces: English-source and Simplified Chinese alert copy.

- [ ] **Step 1: Add localization assertions before catalog entries**

Add a test that reads the source String Catalog and asserts the exact
Simplified Chinese values. `Cancel` is already translated, so the regression
test focuses on the three new keys:

```swift
func testMainWindowCloseAlertHasSimplifiedChineseTranslations() throws {
    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Treemux/Localizable.xcstrings")
    let data = try Data(contentsOf: catalogURL)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(root["strings"] as? [String: Any])

    func chineseValue(_ key: String) throws -> String {
        let entry = try XCTUnwrap(strings[key] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let chinese = try XCTUnwrap(localizations["zh-Hans"] as? [String: Any])
        let unit = try XCTUnwrap(chinese["stringUnit"] as? [String: Any])
        return try XCTUnwrap(unit["value"] as? String)
    }

    XCTAssertEqual(try chineseValue("Close All Windows?"), "关闭所有窗口？")
    XCTAssertEqual(try chineseValue("Close All Windows"), "关闭所有窗口")
    XCTAssertEqual(
        try chineseValue("%lld detached windows are still open. Closing the main window will close all windows and quit Treemux."),
        "仍有 %lld 个已分离窗口处于打开状态。关闭主窗口将关闭所有窗口并退出 Treemux。"
    )
}
```

- [ ] **Step 2: Run the localization test and verify RED**

Run `WindowManagerTests`; expect the three new keys to fail translation checks.

- [ ] **Step 3: Add `zh-Hans` String Catalog entries**

Use these translations:

```text
Close All Windows? → 关闭所有窗口？
%lld detached windows are still open. Closing the main window will close all windows and quit Treemux. → 仍有 %lld 个已分离窗口处于打开状态。关闭主窗口将关闭所有窗口并退出 Treemux。
Close All Windows → 关闭所有窗口
Cancel → 取消（retain the existing catalog entry）
```

- [ ] **Step 4: Run all tests**

```bash
xcodebuild test -quiet -skipPackagePluginValidation \
  -project Treemux.xcodeproj -scheme Treemux \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass with zero failures.

- [ ] **Step 5: Build Debug**

```bash
xcodebuild build -quiet -skipPackagePluginValidation \
  -project Treemux.xcodeproj -scheme Treemux \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: exit code 0 and a Debug app under the active `Treemux-<number>` DerivedData directory.

- [ ] **Step 6: Perform interaction verification**

Verify in the built app:

1. Drag a workspace from the sidebar into the detail area; a child opens and the main sidebar item disappears.
2. Drag another workspace outside Treemux; the same detach behavior occurs.
3. Close a child; its sidebar item returns.
4. With a child open, click the main red close button; choose Cancel and verify every window remains.
5. Repeat and choose Close All Windows; verify all windows close and Treemux quits.
6. With no child open, close the main window and verify no new child-window warning appears.

- [ ] **Step 7: Commit localization and final verification changes**

```bash
git add Treemux/Localizable.xcstrings TreemuxTests/WindowManagerTests.swift
git commit -m "test(detach): cover drag and close confirmation lifecycle"
```
