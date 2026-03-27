# SSH Backend Awareness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make new pane/session creation in remote workspaces use SSH backend instead of hardcoding local shell.

**Architecture:** Add `SessionBackendConfiguration.defaultBackend(for:)` helper, thread `sshTarget: SSHTarget?` through `makeDefault()` and `WorkspaceSessionController`, wire it from `WorkspaceModel`.

**Tech Stack:** Swift, XCTest, macOS/SwiftUI app

---

### Task 1: Add `defaultBackend(for:)` helper with test

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`
- Modify: `Treemux/Domain/SessionBackend.swift:57-62`

**Step 1: Write the failing tests**

Add to `TreemuxTests/WorkspaceModelsTests.swift` at end of class:

```swift
func testDefaultBackendWithNilTargetReturnsLocalShell() {
    let backend = SessionBackendConfiguration.defaultBackend(for: nil)
    if case .localShell = backend {
        // expected
    } else {
        XCTFail("Expected .localShell, got \(backend)")
    }
}

func testDefaultBackendWithSSHTargetReturnsSSH() {
    let target = SSHTarget(
        host: "server1", port: 22, user: "user1",
        identityFile: nil, displayName: "server1", remotePath: "/home/user1"
    )
    let backend = SessionBackendConfiguration.defaultBackend(for: target)
    if case .ssh(let config) = backend {
        XCTAssertEqual(config.target.host, "server1")
        XCTAssertNil(config.remoteCommand)
    } else {
        XCTFail("Expected .ssh, got \(backend)")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testDefaultBackendWithNilTargetReturnsLocalShell -only-testing TreemuxTests/WorkspaceModelsTests/testDefaultBackendWithSSHTargetReturnsSSH 2>&1 | tail -20`
Expected: FAIL — `defaultBackend(for:)` does not exist yet

**Step 3: Write minimal implementation**

Add to `Treemux/Domain/SessionBackend.swift` inside the `SessionBackendConfiguration` enum, after line 61 (before the `CodingKeys`):

```swift
/// Returns the appropriate default backend for the given SSH target.
/// SSH target present → SSH session; nil → local shell.
static func defaultBackend(for sshTarget: SSHTarget?) -> SessionBackendConfiguration {
    if let target = sshTarget {
        return .ssh(SSHSessionConfig(target: target, remoteCommand: nil))
    }
    return .localShell(LocalShellConfig.defaultShell())
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testDefaultBackendWithNilTargetReturnsLocalShell -only-testing TreemuxTests/WorkspaceModelsTests/testDefaultBackendWithSSHTargetReturnsSSH 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add Treemux/Domain/SessionBackend.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat: add SessionBackendConfiguration.defaultBackend(for:) helper"
```

---

### Task 2: Update `makeDefault()` to accept `sshTarget`

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`
- Modify: `Treemux/Domain/WorkspaceModels.swift:85-98`

**Step 1: Write the failing test**

Add to `TreemuxTests/WorkspaceModelsTests.swift`:

```swift
func testMakeDefaultWithSSHTargetCreatesSSHBackend() {
    let target = SSHTarget(
        host: "server1", port: 22, user: "user1",
        identityFile: nil, displayName: "server1", remotePath: "/home/user1"
    )
    let tab = WorkspaceTabStateRecord.makeDefault(
        workingDirectory: "/home/user1",
        sshTarget: target
    )
    XCTAssertEqual(tab.panes.count, 1)
    if case .ssh(let config) = tab.panes[0].backend {
        XCTAssertEqual(config.target.host, "server1")
    } else {
        XCTFail("Expected .ssh backend, got \(tab.panes[0].backend)")
    }
}

func testMakeDefaultWithoutSSHTargetCreatesLocalShell() {
    let tab = WorkspaceTabStateRecord.makeDefault(workingDirectory: "/tmp/test")
    XCTAssertEqual(tab.panes.count, 1)
    if case .localShell = tab.panes[0].backend {
        // expected
    } else {
        XCTFail("Expected .localShell backend")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testMakeDefaultWithSSHTargetCreatesSSHBackend 2>&1 | tail -20`
Expected: FAIL — `makeDefault` does not accept `sshTarget` parameter yet

**Step 3: Write minimal implementation**

Replace `makeDefault()` in `Treemux/Domain/WorkspaceModels.swift:85-98`:

```swift
/// Creates a default single-pane tab for the given working directory.
static func makeDefault(workingDirectory: String, sshTarget: SSHTarget? = nil, title: String = "Tab 1") -> WorkspaceTabStateRecord {
    let paneID = UUID()
    let pane = PaneSnapshot(
        id: paneID,
        backend: .defaultBackend(for: sshTarget),
        workingDirectory: workingDirectory
    )
    return WorkspaceTabStateRecord(
        title: title,
        layout: .pane(PaneLeaf(paneID: paneID)),
        panes: [pane],
        focusedPaneID: paneID
    )
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests 2>&1 | tail -20`
Expected: ALL PASS (new tests + existing `testTabStateRecordMakeDefault` unchanged)

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat: makeDefault() accepts sshTarget for SSH-aware pane creation"
```

---

### Task 3: Thread `sshTarget` through `WorkspaceModel` callers of `makeDefault()`

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:247,275-277,428`

**Step 1: Update `WorkspaceModel.init()` (line 247)**

Change:
```swift
let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: workingDirectory)
```
To:
```swift
let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: workingDirectory, sshTarget: sshTarget)
```

**Step 2: Update `createTab()` (line 275-277)**

Change:
```swift
let newTab = WorkspaceTabStateRecord.makeDefault(
    workingDirectory: activeWorktreePath,
    title: "Tab \(newIndex)"
)
```
To:
```swift
let newTab = WorkspaceTabStateRecord.makeDefault(
    workingDirectory: activeWorktreePath,
    sshTarget: sshTarget,
    title: "Tab \(newIndex)"
)
```

**Step 3: Update `loadActiveWorktreeState()` (line 428)**

Change:
```swift
let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: activeWorktreePath)
```
To:
```swift
let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: activeWorktreePath, sshTarget: sshTarget)
```

**Step 4: Run all existing tests to verify nothing broke**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: pass sshTarget to makeDefault() from WorkspaceModel callers"
```

---

### Task 4: Add `sshTarget` to `WorkspaceSessionController`

**Files:**
- Modify: `TreemuxTests/WorkspaceModelsTests.swift`
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift:12-31,35-53,100-104`

**Step 1: Write the failing tests**

Add to `TreemuxTests/WorkspaceModelsTests.swift`:

```swift
@MainActor
func testEnsureSessionWithSSHTargetCreatesSSHSession() {
    let target = SSHTarget(
        host: "server1", port: 22, user: "user1",
        identityFile: nil, displayName: "server1", remotePath: "/home/user1"
    )
    let ctrl = WorkspaceSessionController(workingDirectory: "/home/user1", sshTarget: target)
    let paneID = ctrl.layout.paneIDs.first!
    let session = ctrl.ensureSession(for: paneID)
    if case .ssh(let config) = session.backendConfiguration {
        XCTAssertEqual(config.target.host, "server1")
    } else {
        XCTFail("Expected .ssh backend, got \(session.backendConfiguration)")
    }
}

@MainActor
func testEnsureSessionWithoutSSHTargetCreatesLocalShell() {
    let ctrl = WorkspaceSessionController(workingDirectory: "/tmp/test")
    let paneID = ctrl.layout.paneIDs.first!
    let session = ctrl.ensureSession(for: paneID)
    if case .localShell = session.backendConfiguration {
        // expected
    } else {
        XCTFail("Expected .localShell backend")
    }
}

@MainActor
func testConvenienceInitFallbackUsesSSHTarget() {
    let target = SSHTarget(
        host: "server1", port: 22, user: "user1",
        identityFile: nil, displayName: "server1", remotePath: "/home/user1"
    )
    let paneID = UUID()
    let savedLayout: SessionLayoutNode = .pane(PaneLeaf(paneID: paneID))
    // Pass empty snapshots to trigger fallback
    let ctrl = WorkspaceSessionController(
        workingDirectory: "/home/user1",
        sshTarget: target,
        savedLayout: savedLayout,
        paneSnapshots: [],
        focusedPaneID: paneID,
        zoomedPaneID: nil
    )
    // The pane exists in layout but had no snapshot, so ensureSession creates it
    let session = ctrl.ensureSession(for: paneID)
    if case .ssh(let config) = session.backendConfiguration {
        XCTAssertEqual(config.target.host, "server1")
    } else {
        XCTFail("Expected .ssh backend from fallback, got \(session.backendConfiguration)")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests/testEnsureSessionWithSSHTargetCreatesSSHSession 2>&1 | tail -20`
Expected: FAIL — `WorkspaceSessionController.init` does not accept `sshTarget` yet

**Step 3: Write implementation**

In `Treemux/Services/Terminal/WorkspaceSessionController.swift`:

**3a.** Add `sshTarget` property (after line 22):

```swift
private let sshTarget: SSHTarget?
```

**3b.** Update `init(workingDirectory:)` (lines 26-31):

```swift
init(workingDirectory: String, sshTarget: SSHTarget? = nil) {
    self.workingDirectory = workingDirectory
    self.sshTarget = sshTarget
    let initialPaneID = UUID()
    self.layout = .pane(PaneLeaf(paneID: initialPaneID))
    self.focusedPaneID = initialPaneID
}
```

**3c.** Update convenience init (lines 35-42) to accept and pass `sshTarget`:

```swift
convenience init(
    workingDirectory: String,
    sshTarget: SSHTarget? = nil,
    savedLayout: SessionLayoutNode?,
    paneSnapshots: [PaneSnapshot],
    focusedPaneID: UUID?,
    zoomedPaneID: UUID?
) {
    self.init(workingDirectory: workingDirectory, sshTarget: sshTarget)
```

**3d.** Update fallback backend in convenience init (line 53):

Change:
```swift
var backend = snapshot?.backend ?? .localShell(LocalShellConfig.defaultShell())
```
To:
```swift
var backend = snapshot?.backend ?? .defaultBackend(for: sshTarget)
```

**3e.** Update `ensureSession(for:)` (lines 102-104):

Change:
```swift
let session = ShellSession(
    id: paneID,
    backendConfiguration: .localShell(LocalShellConfig.defaultShell()),
    preferredWorkingDirectory: workingDirectory
)
```
To:
```swift
let session = ShellSession(
    id: paneID,
    backendConfiguration: .defaultBackend(for: sshTarget),
    preferredWorkingDirectory: workingDirectory
)
```

**Step 4: Verify `backendConfiguration` is accessible on `ShellSession`**

The tests read `session.backendConfiguration`. Check that `ShellSession` exposes this property. If it's not public, add a read-only accessor or adjust the test to check differently. Search for the property:

Run: `grep -n "backendConfiguration" Treemux/Services/Terminal/ShellSession.swift | head -5`

If not accessible, the test assertions may need to use `ctrl.sessions[paneID]` internals or add a test-only accessor. Adjust accordingly.

**Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests/WorkspaceModelsTests 2>&1 | tail -20`
Expected: ALL PASS

**Step 6: Commit**

```bash
git add Treemux/Services/Terminal/WorkspaceSessionController.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat: WorkspaceSessionController uses sshTarget for new sessions"
```

---

### Task 5: Thread `sshTarget` through `WorkspaceModel.controller(forTabID:)`

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:453-459`

**Step 1: Update `controller(forTabID:worktreePath:)` (lines 453-459)**

Change:
```swift
let ctrl = WorkspaceSessionController(
    workingDirectory: worktreePath,
    savedLayout: tabState?.layout,
    paneSnapshots: tabState?.panes ?? [],
    focusedPaneID: tabState?.focusedPaneID,
    zoomedPaneID: tabState?.zoomedPaneID
)
```
To:
```swift
let ctrl = WorkspaceSessionController(
    workingDirectory: worktreePath,
    sshTarget: sshTarget,
    savedLayout: tabState?.layout,
    paneSnapshots: tabState?.panes ?? [],
    focusedPaneID: tabState?.focusedPaneID,
    zoomedPaneID: tabState?.zoomedPaneID
)
```

**Step 2: Run full test suite**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux -only-testing TreemuxTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 3: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift
git commit -m "feat: thread sshTarget from WorkspaceModel to session controller"
```

---

### Task 6: Final verification

**Step 1: Run full test suite**

Run: `xcodebuild test -project Treemux.xcodeproj -scheme Treemux 2>&1 | tail -30`
Expected: ALL PASS

**Step 2: Build for manual testing**

Run: `xcodebuild build -project Treemux.xcodeproj -scheme Treemux -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Verify no remaining hardcoded `.localShell` in session creation paths**

Run: `grep -n "\.localShell(LocalShellConfig" Treemux/Services/Terminal/WorkspaceSessionController.swift Treemux/Domain/WorkspaceModels.swift`
Expected: No matches (all replaced with `.defaultBackend(for:)`)
