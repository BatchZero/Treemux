# Pane Close Button Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a close button (✕) to the right side of each pane's header bar that closes the pane, or closes the tab if it's the last pane.

**Architecture:** Callback-based approach — `TerminalPaneView` receives an `onClose` closure, `SplitNodeView` receives an `onClosePane` closure with paneID, and `WorkspaceSessionDetailView` wires the decision logic (close pane vs close tab). The `WorkspaceSessionController.closePane()` guard is relaxed to allow closing the last pane, returning a flag so the caller knows to close the tab.

**Tech Stack:** SwiftUI, SF Symbols, existing ThemeManager

---

### Task 1: Modify `WorkspaceSessionController.closePane()` to support last-pane closing

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift:142-161`
- Test: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write a failing test for closing the last pane**

In `TreemuxTests/WorkspaceModelsTests.swift`, add a test that verifies `closePane()` returns `true` when it was the last pane:

```swift
@MainActor
func testClosePaneReturnsWasLastPane() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    let tabID = ws.tabs[0].id
    ws.selectTab(tabID)
    guard let controller = ws.sessionController else {
        XCTFail("Expected session controller")
        return
    }
    let paneIDs = controller.layout.paneIDs
    XCTAssertEqual(paneIDs.count, 1)

    let wasLast = controller.closePane(paneIDs[0])
    XCTAssertTrue(wasLast)
}
```

**Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testClosePaneReturnsWasLastPane 2>&1 | tail -20`
Expected: FAIL — `closePane` currently returns `Void` and has an early return for the last pane.

**Step 3: Modify `closePane()` to return a Bool**

In `Treemux/Services/Terminal/WorkspaceSessionController.swift`, change the `closePane` method:

```swift
// MARK: - Pane closing

/// Closes the given pane, terminating its session and collapsing the layout.
/// Returns `true` if this was the last pane (caller should close the tab).
@discardableResult
func closePane(_ paneID: UUID) -> Bool {
    let allIDs = layout.paneIDs
    if allIDs.count <= 1 {
        // Last pane — terminate session but don't modify layout.
        // Return true so the caller can close the tab.
        sessions[paneID]?.terminate()
        sessions.removeValue(forKey: paneID)
        return true
    }

    sessions[paneID]?.terminate()
    sessions.removeValue(forKey: paneID)
    layout.removePane(paneID)

    if focusedPaneID == paneID {
        focusedPaneID = layout.paneIDs.first
    }
    if zoomedPaneID == paneID {
        zoomedPaneID = nil
    }
    onPaneStateChanged?()
    return false
}
```

**Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testClosePaneReturnsWasLastPane 2>&1 | tail -20`
Expected: PASS

**Step 5: Run all existing tests to check for regressions**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -30`
Expected: All tests PASS. Existing callers of `closePane` ignore the return value thanks to `@discardableResult`.

**Step 6: Commit**

```bash
git add Treemux/Services/Terminal/WorkspaceSessionController.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat: make closePane return Bool indicating last-pane status"
```

---

### Task 2: Add close button to `TerminalPaneView`

**Files:**
- Modify: `Treemux/UI/Workspace/TerminalPaneView.swift`

**Step 1: Add `onClose` parameter to `TerminalPaneView`**

Add a closure property and the close button to the pane header. In `Treemux/UI/Workspace/TerminalPaneView.swift`:

Change the struct declaration to add the callback:

```swift
struct TerminalPaneView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var session: ShellSession
    var onClose: () -> Void

    @State private var isCloseHovered = false
```

**Step 2: Add the close button at the end of `paneHeader`**

In the `paneHeader` computed property, add the close button after the working directory text (before the closing `}` of the HStack):

```swift
            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isCloseHovered ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? theme.dividerColor : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCloseHovered = hovering
            }
            .help("Close Pane")
```

**Step 3: Build to check for compilation errors**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -20`
Expected: FAIL — `SplitNodeView` creates `TerminalPaneView` without the new `onClose` parameter. This is expected; we'll fix it in Task 3.

**Step 4: Commit work-in-progress**

```bash
git add Treemux/UI/Workspace/TerminalPaneView.swift
git commit -m "feat: add close button UI to pane header"
```

---

### Task 3: Wire up close callback through `SplitNodeView` and `WorkspaceDetailView`

**Files:**
- Modify: `Treemux/UI/Workspace/SplitNodeView.swift`
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift`

**Step 1: Add `onClosePane` callback to `SplitNodeView`**

In `Treemux/UI/Workspace/SplitNodeView.swift`, add a closure that takes a paneID:

```swift
struct SplitNodeView: View {
    @ObservedObject var sessionController: WorkspaceSessionController
    let node: SessionLayoutNode
    var onClosePane: (UUID) -> Void
```

**Step 2: Pass `onClose` to `TerminalPaneView` in leaf nodes**

Update the `body` (zoomed case) and `nodeBody` (normal case) to pass the closure:

In `body` — zoomed pane case:
```swift
if let zoomedID = sessionController.zoomedPaneID {
    let session = sessionController.ensureSession(for: zoomedID)
    TerminalPaneView(session: session, onClose: { onClosePane(zoomedID) })
}
```

In `nodeBody` — `.pane` case:
```swift
case .pane(let leaf):
    let session = sessionController.ensureSession(for: leaf.paneID)
    TerminalPaneView(session: session, onClose: { onClosePane(leaf.paneID) })
```

**Step 3: Pass `onClosePane` to recursive `SplitNodeView` children**

In `splitBody`, update both recursive `SplitNodeView` calls to forward the callback:

```swift
SplitNodeView(sessionController: sessionController, node: split.first, onClosePane: onClosePane)
// ...
SplitNodeView(sessionController: sessionController, node: split.second, onClosePane: onClosePane)
```

(There are 4 total: 2 in the horizontal branch, 2 in the vertical branch.)

**Step 4: Wire up the callback in `WorkspaceDetailView`**

In `Treemux/UI/Workspace/WorkspaceDetailView.swift`, modify `WorkspaceSessionDetailView` to pass the close logic:

```swift
private struct WorkspaceSessionDetailView: View {
    @ObservedObject var controller: WorkspaceSessionController
    var onCloseTab: () -> Void

    var body: some View {
        SplitNodeView(
            sessionController: controller,
            node: controller.layout,
            onClosePane: { paneID in
                let wasLast = controller.closePane(paneID)
                if wasLast {
                    onCloseTab()
                }
            }
        )
    }
}
```

Then update `WorkspaceTabContainerView` to pass `onCloseTab`:

```swift
if let controller = workspace.sessionController {
    WorkspaceSessionDetailView(
        controller: controller,
        onCloseTab: { workspace.closeTab(workspace.activeTabID!) }
    )
    .id(workspace.activeTabID)
}
```

**Step 5: Build and verify compilation**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -20`
Expected: PASS — all call sites now provide the required parameters.

**Step 6: Run all tests**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -30`
Expected: All tests PASS.

**Step 7: Commit**

```bash
git add Treemux/UI/Workspace/SplitNodeView.swift Treemux/UI/Workspace/WorkspaceDetailView.swift
git commit -m "feat: wire pane close button through view hierarchy"
```

---

### Task 4: Add i18n support for close button tooltip

**Files:**
- Modify: `Treemux/Localizable.xcstrings`

**Step 1: Add localization entry for "Close Pane"**

In `Treemux/Localizable.xcstrings`, add the `zh-Hans` translation for `"Close Pane"`:

- Key: `"Close Pane"`
- `zh-Hans` value: `"关闭面板"`

**Step 2: Verify it builds**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -20`
Expected: PASS

**Step 3: Commit**

```bash
git add Treemux/Localizable.xcstrings
git commit -m "i18n: add zh-Hans translation for Close Pane tooltip"
```

---

### Task 5: Manual QA and final verification

**Step 1: Run all tests one final time**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -30`
Expected: All tests PASS.

**Step 2: Build the app**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -10`

**Step 3: Launch and test manually**

Verify:
- [ ] Close button (✕) visible in pane header, right side
- [ ] Hover highlights the button with circular background
- [ ] Click closes the pane when multiple panes exist
- [ ] Click closes the tab when only one pane remains
- [ ] Empty workspace state shows "new tab" button after last tab closed
- [ ] Zoomed pane close button works correctly
- [ ] Tooltip shows "关闭面板" in Chinese locale

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address QA findings for pane close button"
```
