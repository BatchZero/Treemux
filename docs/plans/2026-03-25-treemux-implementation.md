# Treemux Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS terminal workspace app with libghostty embedding, git worktree management, SSH remote support, tmux restoration, theme system, i18n, and AI tool integration.

**Architecture:** Layered Swift app (App → Domain → Services → UI) using SwiftUI + AppKit with NSApplication lifecycle. Ghostty provides terminal rendering via vendored GhosttyKit.xcframework static library. State persisted as JSON files in `~/.treemux/`.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSOutlineView for sidebar), GhosttyKit (libghostty), XCTest, xcodebuild, macOS 15+, Apple Silicon.

**Reference Codebase:** Liney at `/Users/yanu/Documents/code/Terminal/liney/` — use as reference for Ghostty integration patterns, pane layout, and git service implementation.

**Design Document:** `docs/plans/2026-03-25-treemux-design.md`

---

## Phase P0: Minimum Viable Product

### Task 1: Create Xcode Project and Directory Structure

**Files:**
- Create: `Treemux.xcodeproj` (via Xcode CLI or manually)
- Create: `Treemux/main.swift`
- Create: `Treemux/AppDelegate.swift`
- Create: `Treemux/Info.plist`
- Create: directory structure under `Treemux/`

**Step 1: Create the Xcode project**

Use Xcode to create a new macOS App project:
- Product Name: `Treemux`
- Team: (your team)
- Organization Identifier: `com.batchzero`
- Bundle Identifier: `com.batchzero.treemux`
- Interface: SwiftUI
- Language: Swift
- Uncheck "Include Tests" (we'll add tests manually later)

Then restructure to use NSApplication lifecycle instead of SwiftUI App lifecycle.

**Step 2: Replace the default SwiftUI App entry point with NSApplication**

Delete the auto-generated `TreemuxApp.swift` and create `main.swift`:

```swift
// main.swift
import Cocoa

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    app.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

**Step 3: Create AppDelegate.swift**

```swift
// AppDelegate.swift
import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Minimal launch — just open a window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Treemux"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

**Step 4: Create the directory structure**

Create all subdirectories inside `Treemux/`:

```
Treemux/
├─ App/
├─ Domain/
├─ Persistence/
├─ Services/
│  ├─ Git/
│  ├─ Terminal/
│  │  └─ Ghostty/
│  ├─ SSH/
│  ├─ Tmux/
│  ├─ AITool/
│  └─ Process/
├─ UI/
│  ├─ Sidebar/
│  ├─ Workspace/
│  ├─ Sheets/
│  ├─ Theme/
│  ├─ Settings/
│  └─ Components/
├─ Support/
└─ Vendor/
```

**Step 5: Configure build settings**

In Xcode project settings:
- Deployment Target: macOS 15.0
- Swift Language Version: Swift 6 (or 5 if Swift 6 concurrency issues arise)
- App Sandbox: NO
- Hardened Runtime: YES
- Other Linker Flags: `-lc++ -framework Carbon`
- LD_RUNPATH_SEARCH_PATHS: `$(inherited) @executable_path/../Frameworks`
- ENABLE_USER_SCRIPT_SANDBOXING: NO

**Step 6: Update Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 BatchZero. MIT License.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
```

**Step 7: Build and run to verify empty window appears**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS,arch=arm64' build`

Expected: Build succeeds, app launches with empty "Treemux" window.

**Step 8: Commit**

```bash
git add Treemux.xcodeproj Treemux/
git commit -m "feat: initialize Xcode project with NSApplication lifecycle"
```

---

### Task 2: Vendor GhosttyKit and Bootstrap Ghostty

**Files:**
- Copy: `Treemux/Vendor/GhosttyKit.xcframework` (from Liney)
- Copy: `Treemux/ghostty/shell-integration/` (from Liney)
- Copy: `Treemux/terminfo/` (from Liney)
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyBootstrap.swift`
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyLogFilter.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/Ghostty/LineyGhosttyBootstrap.swift`
**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/Ghostty/LineyGhosttyLogFilter.swift`

**Step 1: Copy GhosttyKit.xcframework from Liney**

```bash
cp -R /Users/yanu/Documents/code/Terminal/liney/Liney/Vendor/GhosttyKit.xcframework \
      Treemux/Vendor/GhosttyKit.xcframework
```

**Step 2: Copy shell integration and terminfo from Liney**

```bash
cp -R /Users/yanu/Documents/code/Terminal/liney/Liney/ghostty Treemux/ghostty
cp -R /Users/yanu/Documents/code/Terminal/liney/Liney/terminfo Treemux/terminfo
```

**Step 3: Add GhosttyKit.xcframework to Xcode project**

In Xcode:
1. Drag `Treemux/Vendor/GhosttyKit.xcframework` into the project navigator
2. In target → General → Frameworks, Libraries, and Embedded Content, ensure GhosttyKit is listed as "Do Not Embed" (static library)

**Step 4: Add "Copy Ghostty Resources" build phase**

In Xcode target → Build Phases → New Run Script Phase, add:

```bash
set -e
RESOURCE_ROOT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$RESOURCE_ROOT/ghostty" "$RESOURCE_ROOT/terminfo"
rsync -a "$SRCROOT/Treemux/ghostty/" "$RESOURCE_ROOT/ghostty/"
rsync -a "$SRCROOT/Treemux/terminfo/" "$RESOURCE_ROOT/terminfo/"
```

Name it "Copy Ghostty Resources". Set "Based on dependency analysis" to NO.

**Step 5: Create TreemuxGhosttyLogFilter.swift**

Reference `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/Ghostty/LineyGhosttyLogFilter.swift` and adapt for Treemux naming:

```swift
// Treemux/Services/Terminal/Ghostty/TreemuxGhosttyLogFilter.swift
import Foundation
import os

// Suppress verbose Ghostty log output that clutters the console
enum TreemuxGhosttyLogFilter {
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        // Redirect stderr to suppress Ghostty debug logs in production
        #if !DEBUG
        let devNull = fopen("/dev/null", "w")
        if let devNull {
            dup2(fileno(devNull), STDERR_FILENO)
            fclose(devNull)
        }
        #endif
    }
}
```

**Step 6: Create TreemuxGhosttyBootstrap.swift**

```swift
// Treemux/Services/Terminal/Ghostty/TreemuxGhosttyBootstrap.swift
import Foundation
import GhosttyKit

enum TreemuxGhosttyBootstrap {
    private static let initialized: Void = {
        TreemuxGhosttyLogFilter.installIfNeeded()
        applyProcessEnvironment()
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            fatalError("Failed to initialize libghostty")
        }
    }()

    static func initialize() {
        _ = initialized
    }

    private static func applyProcessEnvironment() {
        let env = processEnvironment()
        for (key, value) in env {
            setenv(key, value, 1)
        }
    }

    static func processEnvironment() -> [String: String] {
        guard let resourcesDir = Bundle.main.resourcePath else {
            return [:]
        }
        let ghosttyDir = (resourcesDir as NSString).appendingPathComponent("ghostty")
        return ["GHOSTTY_RESOURCES_DIR": ghosttyDir]
    }
}
```

**Step 7: Update AppDelegate to call bootstrap**

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    TreemuxGhosttyBootstrap.initialize()
    // ... rest of window setup
}
```

**Step 8: Build and run**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS,arch=arm64' build`

Expected: Build succeeds, Ghostty initializes without crash.

**Step 9: Commit**

```bash
git add Treemux/Vendor/ Treemux/ghostty/ Treemux/terminfo/ Treemux/Services/Terminal/Ghostty/
git commit -m "feat: vendor GhosttyKit and bootstrap libghostty"
```

---

### Task 3: Domain Models — Pane Layout

**Files:**
- Create: `Treemux/Domain/PaneLayout.swift`
- Create: `Tests/PaneLayoutTests.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Domain/PaneLayout.swift`

**Step 1: Write failing tests for PaneLayout**

```swift
// Tests/PaneLayoutTests.swift
import XCTest
@testable import Treemux

final class PaneLayoutTests: XCTestCase {

    func testSinglePaneLayout() throws {
        let paneID = UUID()
        let layout = SessionLayoutNode.pane(PaneLeaf(paneID: paneID))
        XCTAssertEqual(layout.paneIDs, [paneID])
    }

    func testSplitLayoutContainsBothPanes() throws {
        let left = UUID()
        let right = UUID()
        let layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .horizontal,
            fraction: 0.5,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))
        XCTAssertEqual(Set(layout.paneIDs), Set([left, right]))
    }

    func testLayoutCodableRoundTrip() throws {
        let left = UUID()
        let right = UUID()
        let layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .vertical,
            fraction: 0.3,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(SessionLayoutNode.self, from: data)
        XCTAssertEqual(decoded.paneIDs.count, 2)
        XCTAssertTrue(decoded.paneIDs.contains(left))
        XCTAssertTrue(decoded.paneIDs.contains(right))
    }

    func testRemovePaneFromSplit() throws {
        let left = UUID()
        let right = UUID()
        var layout = SessionLayoutNode.split(PaneSplitNode(
            axis: .horizontal,
            fraction: 0.5,
            first: .pane(PaneLeaf(paneID: left)),
            second: .pane(PaneLeaf(paneID: right))
        ))
        layout.removePane(left)
        XCTAssertEqual(layout.paneIDs, [right])
    }

    func testFractionClamping() throws {
        let node = PaneSplitNode(
            axis: .horizontal,
            fraction: 0.05,  // below minimum
            first: .pane(PaneLeaf(paneID: UUID())),
            second: .pane(PaneLeaf(paneID: UUID()))
        )
        XCTAssertGreaterThanOrEqual(node.clampedFraction, 0.12)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS,arch=arm64' test`

Expected: FAIL — types not defined.

**Step 3: Implement PaneLayout.swift**

```swift
// Treemux/Domain/PaneLayout.swift
import Foundation

enum SplitAxis: String, Codable {
    case horizontal
    case vertical
}

struct PaneLeaf: Codable, Equatable {
    let paneID: UUID
}

struct PaneSplitNode: Codable {
    var axis: SplitAxis
    var fraction: Double
    var first: SessionLayoutNode
    var second: SessionLayoutNode

    static let minimumFraction: Double = 0.12
    static let maximumFraction: Double = 0.88

    var clampedFraction: Double {
        min(max(fraction, Self.minimumFraction), Self.maximumFraction)
    }
}

indirect enum SessionLayoutNode: Codable {
    case pane(PaneLeaf)
    case split(PaneSplitNode)

    var paneIDs: [UUID] {
        switch self {
        case .pane(let leaf):
            return [leaf.paneID]
        case .split(let node):
            return node.first.paneIDs + node.second.paneIDs
        }
    }

    mutating func removePane(_ id: UUID) {
        switch self {
        case .pane:
            return
        case .split(let node):
            if case .pane(let leaf) = node.first, leaf.paneID == id {
                self = node.second
                return
            }
            if case .pane(let leaf) = node.second, leaf.paneID == id {
                self = node.first
                return
            }
            var mutableNode = node
            mutableNode.first.removePane(id)
            mutableNode.second.removePane(id)
            self = .split(mutableNode)
        }
    }

    // Navigate to adjacent pane in a given direction
    func paneID(in direction: SplitDirection, from currentID: UUID) -> UUID? {
        let ids = paneIDs
        guard let index = ids.firstIndex(of: currentID) else { return nil }
        switch direction {
        case .next:
            let nextIndex = (index + 1) % ids.count
            return ids[nextIndex]
        case .previous:
            let prevIndex = (index - 1 + ids.count) % ids.count
            return ids[prevIndex]
        }
    }
}

enum SplitDirection {
    case next
    case previous
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -destination 'platform=macOS,arch=arm64' test`

Expected: All PaneLayoutTests PASS.

**Step 5: Commit**

```bash
git add Treemux/Domain/PaneLayout.swift Tests/PaneLayoutTests.swift
git commit -m "feat: add PaneLayout domain model with recursive binary tree"
```

---

### Task 4: Domain Models — Session Backend Configuration

**Files:**
- Create: `Treemux/Domain/SessionBackend.swift`
- Create: `Treemux/Domain/SSHTarget.swift`
- Create: `Tests/SessionBackendTests.swift`

**Step 1: Write failing tests**

```swift
// Tests/SessionBackendTests.swift
import XCTest
@testable import Treemux

final class SessionBackendTests: XCTestCase {

    func testLocalShellCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.localShell(LocalShellConfig(
            shellPath: "/bin/zsh",
            arguments: ["--login"]
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .localShell(let shell) = decoded {
            XCTAssertEqual(shell.shellPath, "/bin/zsh")
            XCTAssertEqual(shell.arguments, ["--login"])
        } else {
            XCTFail("Expected localShell")
        }
    }

    func testSSHTargetCodableRoundTrip() throws {
        let target = SSHTarget(
            host: "192.168.1.100",
            port: 22,
            user: "user1",
            identityFile: "~/.ssh/id_rsa",
            displayName: "server1",
            remotePath: "/home/user1/project"
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(SSHTarget.self, from: data)
        XCTAssertEqual(decoded.host, "192.168.1.100")
        XCTAssertEqual(decoded.user, "user1")
        XCTAssertEqual(decoded.displayName, "server1")
    }

    func testTmuxAttachCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.tmuxAttach(TmuxAttachConfig(
            sessionName: "dev",
            windowIndex: nil,
            isRemote: true,
            sshTarget: SSHTarget(
                host: "server1",
                port: 22,
                user: "user1",
                identityFile: nil,
                displayName: "server1",
                remotePath: nil
            )
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .tmuxAttach(let tmux) = decoded {
            XCTAssertEqual(tmux.sessionName, "dev")
            XCTAssertTrue(tmux.isRemote)
            XCTAssertEqual(tmux.sshTarget?.host, "server1")
        } else {
            XCTFail("Expected tmuxAttach")
        }
    }

    func testAgentConfigCodableRoundTrip() throws {
        let config = SessionBackendConfiguration.agent(AgentSessionConfig(
            name: "Claude Code",
            launchCommand: "claude",
            arguments: [],
            environment: [:],
            toolKind: .claudeCode
        ))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SessionBackendConfiguration.self, from: data)
        if case .agent(let agent) = decoded {
            XCTAssertEqual(agent.name, "Claude Code")
            XCTAssertEqual(agent.toolKind, .claudeCode)
        } else {
            XCTFail("Expected agent")
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — types not defined.

**Step 3: Implement SSHTarget.swift**

```swift
// Treemux/Domain/SSHTarget.swift
import Foundation

struct SSHTarget: Codable, Hashable {
    let host: String
    let port: Int
    let user: String?
    let identityFile: String?
    let displayName: String
    let remotePath: String?
}
```

**Step 4: Implement SessionBackend.swift**

```swift
// Treemux/Domain/SessionBackend.swift
import Foundation

struct LocalShellConfig: Codable {
    let shellPath: String
    let arguments: [String]

    static func defaultShell() -> LocalShellConfig {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return LocalShellConfig(shellPath: shell, arguments: ["--login"])
    }
}

struct SSHSessionConfig: Codable {
    let target: SSHTarget
    let remoteCommand: String?
}

enum AIToolKind: String, Codable {
    case claudeCode = "claude"
    case openaiCodex = "codex"
    case custom
}

struct AgentSessionConfig: Codable {
    let name: String
    let launchCommand: String
    let arguments: [String]
    let environment: [String: String]
    let toolKind: AIToolKind?
}

struct TmuxAttachConfig: Codable {
    let sessionName: String
    let windowIndex: Int?
    let isRemote: Bool
    let sshTarget: SSHTarget?
}

enum SessionBackendConfiguration: Codable {
    case localShell(LocalShellConfig)
    case ssh(SSHSessionConfig)
    case agent(AgentSessionConfig)
    case tmuxAttach(TmuxAttachConfig)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum BackendType: String, Codable {
        case localShell, ssh, agent, tmuxAttach
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localShell(let config):
            try container.encode(BackendType.localShell, forKey: .type)
            try config.encode(to: encoder)
        case .ssh(let config):
            try container.encode(BackendType.ssh, forKey: .type)
            try config.encode(to: encoder)
        case .agent(let config):
            try container.encode(BackendType.agent, forKey: .type)
            try config.encode(to: encoder)
        case .tmuxAttach(let config):
            try container.encode(BackendType.tmuxAttach, forKey: .type)
            try config.encode(to: encoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(BackendType.self, forKey: .type)
        switch type {
        case .localShell:
            self = .localShell(try LocalShellConfig(from: decoder))
        case .ssh:
            self = .ssh(try SSHSessionConfig(from: decoder))
        case .agent:
            self = .agent(try AgentSessionConfig(from: decoder))
        case .tmuxAttach:
            self = .tmuxAttach(try TmuxAttachConfig(from: decoder))
        }
    }
}
```

**Step 5: Run tests to verify they pass**

Expected: All SessionBackendTests PASS.

**Step 6: Commit**

```bash
git add Treemux/Domain/SessionBackend.swift Treemux/Domain/SSHTarget.swift Tests/SessionBackendTests.swift
git commit -m "feat: add session backend and SSH target domain models"
```

---

### Task 5: Domain Models — Workspace Models

**Files:**
- Create: `Treemux/Domain/WorkspaceModels.swift`
- Create: `Tests/WorkspaceModelsTests.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Domain/WorkspaceModels.swift`

**Step 1: Write failing tests**

```swift
// Tests/WorkspaceModelsTests.swift
import XCTest
@testable import Treemux

final class WorkspaceModelsTests: XCTestCase {

    func testWorkspaceRecordCodableRoundTrip() throws {
        let record = WorkspaceRecord(
            id: UUID(),
            kind: .repository,
            name: "my-project",
            repositoryPath: "/Users/test/code/my-project",
            isPinned: false,
            isArchived: false,
            sshTarget: nil,
            worktreeStates: []
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.name, "my-project")
        XCTAssertEqual(decoded.kind, .repository)
    }

    func testRemoteWorkspaceRecordCodable() throws {
        let target = SSHTarget(
            host: "server1", port: 22, user: "user1",
            identityFile: nil, displayName: "server1", remotePath: "/home/user1/proj"
        )
        let record = WorkspaceRecord(
            id: UUID(),
            kind: .remote,
            name: "proj",
            repositoryPath: nil,
            isPinned: false,
            isArchived: false,
            sshTarget: target,
            worktreeStates: []
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(decoded.kind, .remote)
        XCTAssertEqual(decoded.sshTarget?.host, "server1")
    }

    func testPersistedWorkspaceStateCodable() throws {
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: []
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.workspaces.isEmpty)
    }

    func testPaneSnapshotCodable() throws {
        let snapshot = PaneSnapshot(
            id: UUID(),
            backend: .localShell(LocalShellConfig.defaultShell()),
            workingDirectory: "/Users/test/code"
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        XCTAssertEqual(decoded.workingDirectory, "/Users/test/code")
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — types not defined.

**Step 3: Implement WorkspaceModels.swift**

```swift
// Treemux/Domain/WorkspaceModels.swift
import Foundation

// MARK: - Persistent Records (Codable)

enum WorkspaceKindRecord: String, Codable {
    case repository
    case localTerminal
    case remote
}

struct WorkspaceRecord: Codable {
    let id: UUID
    let kind: WorkspaceKindRecord
    let name: String
    let repositoryPath: String?
    let isPinned: Bool
    let isArchived: Bool
    let sshTarget: SSHTarget?
    let worktreeStates: [WorktreeSessionStateRecord]
}

struct WorktreeSessionStateRecord: Codable {
    let worktreePath: String
    let branch: String?
    let tabs: [WorkspaceTabStateRecord]
    let selectedTabID: UUID?
}

struct WorkspaceTabStateRecord: Codable {
    let id: UUID
    let title: String
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
}

struct PaneSnapshot: Codable {
    let id: UUID
    let backend: SessionBackendConfiguration
    let workingDirectory: String?
}

struct PersistedWorkspaceState: Codable {
    let version: Int
    let selectedWorkspaceID: UUID?
    let workspaces: [WorkspaceRecord]
}

// MARK: - Runtime Models

struct WorktreeModel: Identifiable {
    let id: UUID
    let path: URL
    let branch: String?
    let headCommit: String?
    let isMainWorktree: Bool
}

struct RepositorySnapshot {
    let currentBranch: String?
    let headCommit: String?
    let worktrees: [WorktreeModel]
    let status: RepositoryStatusSnapshot?
}

struct RepositoryStatusSnapshot {
    let changedFileCount: Int
    let aheadCount: Int
    let behindCount: Int
    let untrackedCount: Int
}
```

**Step 4: Run tests to verify they pass**

Expected: All WorkspaceModelsTests PASS.

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift Tests/WorkspaceModelsTests.swift
git commit -m "feat: add workspace domain models with persistence records"
```

---

### Task 6: Persistence Layer

**Files:**
- Create: `Treemux/Persistence/AppSettingsPersistence.swift`
- Create: `Treemux/Persistence/WorkspaceStatePersistence.swift`
- Create: `Treemux/Domain/AppSettings.swift`
- Create: `Tests/PersistenceTests.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Persistence/`

**Step 1: Write failing tests**

```swift
// Tests/PersistenceTests.swift
import XCTest
@testable import Treemux

final class PersistenceTests: XCTestCase {

    func testAppSettingsDefaultValues() {
        let settings = AppSettings()
        XCTAssertEqual(settings.language, "system")
        XCTAssertEqual(settings.activeThemeID, "treemux-dark")
        XCTAssertTrue(settings.startup.restoreLastSession)
    }

    func testAppSettingsCodableRoundTrip() throws {
        var settings = AppSettings()
        settings.language = "zh-Hans"
        settings.activeThemeID = "treemux-light"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.language, "zh-Hans")
        XCTAssertEqual(decoded.activeThemeID, "treemux-light")
    }

    func testTreemuxStateDirectoryName() {
        #if DEBUG
        XCTAssertEqual(treemuxStateDirectoryName(), ".treemux-debug")
        #else
        XCTAssertEqual(treemuxStateDirectoryName(), ".treemux")
        #endif
    }

    func testAppSettingsSaveAndLoad() throws {
        let persistence = AppSettingsPersistence()
        var settings = AppSettings()
        settings.language = "en"
        try persistence.save(settings)
        let loaded = persistence.load()
        XCTAssertEqual(loaded.language, "en")
    }

    func testWorkspaceStateSaveAndLoad() throws {
        let persistence = WorkspaceStatePersistence()
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: nil,
            workspaces: [
                WorkspaceRecord(
                    id: UUID(), kind: .repository, name: "test",
                    repositoryPath: "/tmp/test", isPinned: false,
                    isArchived: false, sshTarget: nil, worktreeStates: []
                )
            ]
        )
        try persistence.save(state)
        let loaded = persistence.load()
        XCTAssertEqual(loaded.workspaces.count, 1)
        XCTAssertEqual(loaded.workspaces.first?.name, "test")
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — types not defined.

**Step 3: Implement AppSettings.swift**

```swift
// Treemux/Domain/AppSettings.swift
import Foundation

struct AppSettings: Codable {
    var version: Int = 1
    var language: String = "system"
    var activeThemeID: String = "treemux-dark"
    var terminal: TerminalSettings = TerminalSettings()
    var startup: StartupSettings = StartupSettings()
    var ssh: SSHSettings = SSHSettings()
    var aiTools: AIToolSettings = AIToolSettings()
}

struct TerminalSettings: Codable {
    var defaultShell: String = "/bin/zsh"
    var fontSize: Int = 14
    var cursorStyle: String = "block"
}

struct StartupSettings: Codable {
    var restoreLastSession: Bool = true
}

struct SSHSettings: Codable {
    var configPaths: [String] = ["~/.ssh/config"]
}

struct AIToolSettings: Codable {
    var autoDetect: Bool = true
}
```

**Step 4: Implement persistence files**

```swift
// Treemux/Persistence/AppSettingsPersistence.swift
import Foundation

private let treemuxPersistenceIsDebugBuild: Bool = {
    #if DEBUG
    true
    #else
    false
    #endif
}()

func treemuxStateDirectoryName(isDebugBuild: Bool = treemuxPersistenceIsDebugBuild) -> String {
    isDebugBuild ? ".treemux-debug" : ".treemux"
}

func treemuxStateDirectoryURL(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        treemuxStateDirectoryName(),
        isDirectory: true
    )
}

struct AppSettingsPersistence {
    private let fileManager = FileManager.default

    func load() -> AppSettings {
        let url = settingsFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func save(_ settings: AppSettings) throws {
        let directory = stateDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsFileURL(), options: .atomic)
    }

    private func stateDirectoryURL() -> URL {
        treemuxStateDirectoryURL(fileManager: fileManager)
    }

    private func settingsFileURL() -> URL {
        stateDirectoryURL().appendingPathComponent("settings.json")
    }
}
```

```swift
// Treemux/Persistence/WorkspaceStatePersistence.swift
import Foundation

struct WorkspaceStatePersistence {
    private let fileManager = FileManager.default

    func load() -> PersistedWorkspaceState {
        let url = stateFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [])
        }
        do {
            return try JSONDecoder().decode(PersistedWorkspaceState.self, from: data)
        } catch {
            return PersistedWorkspaceState(version: 1, selectedWorkspaceID: nil, workspaces: [])
        }
    }

    func save(_ state: PersistedWorkspaceState) throws {
        let directory = stateDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateFileURL(), options: .atomic)
    }

    private func stateDirectoryURL() -> URL {
        treemuxStateDirectoryURL(fileManager: fileManager)
    }

    private func stateFileURL() -> URL {
        stateDirectoryURL().appendingPathComponent("workspace-state.json")
    }
}
```

**Step 5: Run tests to verify they pass**

Expected: All PersistenceTests PASS.

**Step 6: Commit**

```bash
git add Treemux/Domain/AppSettings.swift Treemux/Persistence/ Tests/PersistenceTests.swift
git commit -m "feat: add persistence layer with JSON file storage"
```

---

### Task 7: Shell Command Runner Service

**Files:**
- Create: `Treemux/Services/Process/ShellCommandRunner.swift`
- Create: `Tests/ShellCommandRunnerTests.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Process/ShellCommandRunner.swift`

**Step 1: Write failing tests**

```swift
// Tests/ShellCommandRunnerTests.swift
import XCTest
@testable import Treemux

final class ShellCommandRunnerTests: XCTestCase {

    func testRunEchoCommand() async throws {
        let result = try await ShellCommandRunner.run("echo", arguments: ["hello"])
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRunFailingCommand() async throws {
        let result = try await ShellCommandRunner.run("false")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testRunWithWorkingDirectory() async throws {
        let result = try await ShellCommandRunner.run("pwd", workingDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(result.output.contains("/tmp") || result.output.contains("/private/tmp"))
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — ShellCommandRunner not defined.

**Step 3: Implement ShellCommandRunner.swift**

```swift
// Treemux/Services/Process/ShellCommandRunner.swift
import Foundation

struct CommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

enum ShellCommandRunner {
    static func run(
        _ command: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.hasPrefix("/") ? command : "/usr/bin/\(command)")
        process.arguments = arguments

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        if let environment {
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CommandResult(
                    output: stdout,
                    errorOutput: stderr,
                    exitCode: proc.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a shell command via /bin/sh -c
    static func shell(_ command: String, workingDirectory: URL? = nil) async throws -> CommandResult {
        try await run("/bin/sh", arguments: ["-c", command], workingDirectory: workingDirectory)
    }
}
```

**Step 4: Run tests to verify they pass**

Expected: All ShellCommandRunnerTests PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/Process/ShellCommandRunner.swift Tests/ShellCommandRunnerTests.swift
git commit -m "feat: add shell command runner service"
```

---

### Task 8: Git Repository Service

**Files:**
- Create: `Treemux/Services/Git/GitRepositoryService.swift`
- Create: `Tests/GitRepositoryServiceTests.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Git/GitRepositoryService.swift`

**Step 1: Write failing tests**

```swift
// Tests/GitRepositoryServiceTests.swift
import XCTest
@testable import Treemux

final class GitRepositoryServiceTests: XCTestCase {

    private var testRepoURL: URL!
    private let service = GitRepositoryService()

    override func setUp() async throws {
        // Create a temporary git repo for testing
        testRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testRepoURL, withIntermediateDirectories: true)
        _ = try await ShellCommandRunner.shell("git init && git commit --allow-empty -m 'init'", workingDirectory: testRepoURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: testRepoURL)
    }

    func testCurrentBranch() async throws {
        let branch = try await service.currentBranch(at: testRepoURL)
        XCTAssertFalse(branch.isEmpty)
    }

    func testRepositoryRoot() async throws {
        let root = try await service.repositoryRoot(at: testRepoURL)
        XCTAssertEqual(root.standardizedFileURL, testRepoURL.standardizedFileURL)
    }

    func testListWorktrees() async throws {
        let worktrees = try await service.listWorktrees(at: testRepoURL)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertTrue(worktrees.first?.isMainWorktree ?? false)
    }
}
```

**Step 2: Run tests to verify they fail**

Expected: FAIL — GitRepositoryService not defined.

**Step 3: Implement GitRepositoryService.swift**

```swift
// Treemux/Services/Git/GitRepositoryService.swift
import Foundation

actor GitRepositoryService {

    func repositoryRoot(at path: URL) async throws -> URL {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.notARepository
        }
        return URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func currentBranch(at path: URL) async throws -> String {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func headCommit(at path: URL) async throws -> String {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--short", "HEAD"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func listWorktrees(at path: URL) async throws -> [WorktreeModel] {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["worktree", "list", "--porcelain"],
            workingDirectory: path
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
        return parseWorktreeList(result.output)
    }

    func repositoryStatus(at path: URL) async throws -> RepositoryStatusSnapshot {
        async let statusResult = ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            workingDirectory: path
        )
        async let aheadBehindResult = ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
            workingDirectory: path
        )

        let status = try await statusResult
        let lines = status.output.split(separator: "\n")
        let changedCount = lines.filter { !$0.hasPrefix("??") }.count
        let untrackedCount = lines.filter { $0.hasPrefix("??") }.count

        var ahead = 0
        var behind = 0
        if let ab = try? await aheadBehindResult, ab.exitCode == 0 {
            let parts = ab.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        return RepositoryStatusSnapshot(
            changedFileCount: changedCount,
            aheadCount: ahead,
            behindCount: behind,
            untrackedCount: untrackedCount
        )
    }

    func inspectRepository(at path: URL) async throws -> RepositorySnapshot {
        async let branch = currentBranch(at: path)
        async let head = headCommit(at: path)
        async let worktrees = listWorktrees(at: path)
        let status = try? await repositoryStatus(at: path)

        return RepositorySnapshot(
            currentBranch: try await branch,
            headCommit: try await head,
            worktrees: try await worktrees,
            status: status
        )
    }

    func createWorktree(at repoPath: URL, branch: String, targetPath: URL) async throws {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["worktree", "add", targetPath.path, branch],
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
    }

    func removeWorktree(at repoPath: URL, worktreePath: URL) async throws {
        let result = try await ShellCommandRunner.run(
            "/usr/bin/git",
            arguments: ["worktree", "remove", worktreePath.path],
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result.errorOutput)
        }
    }

    // MARK: - Parsing

    private func parseWorktreeList(_ output: String) -> [WorktreeModel] {
        var worktrees: [WorktreeModel] = []
        var currentPath: String?
        var currentBranch: String?
        var currentHead: String?
        var isMainWorktree = true

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            if lineStr.isEmpty {
                if let path = currentPath {
                    worktrees.append(WorktreeModel(
                        id: UUID(),
                        path: URL(fileURLWithPath: path),
                        branch: currentBranch,
                        headCommit: currentHead,
                        isMainWorktree: isMainWorktree
                    ))
                }
                currentPath = nil
                currentBranch = nil
                currentHead = nil
                isMainWorktree = false
            } else if lineStr.hasPrefix("worktree ") {
                currentPath = String(lineStr.dropFirst("worktree ".count))
            } else if lineStr.hasPrefix("HEAD ") {
                currentHead = String(lineStr.dropFirst("HEAD ".count).prefix(7))
            } else if lineStr.hasPrefix("branch ") {
                let ref = String(lineStr.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            }
        }

        // Handle last entry if no trailing newline
        if let path = currentPath {
            worktrees.append(WorktreeModel(
                id: UUID(),
                path: URL(fileURLWithPath: path),
                branch: currentBranch,
                headCommit: currentHead,
                isMainWorktree: isMainWorktree
            ))
        }

        return worktrees
    }
}

enum GitError: Error, LocalizedError {
    case notARepository
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notARepository: return "Not a git repository"
        case .commandFailed(let msg): return "Git command failed: \(msg)"
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Expected: All GitRepositoryServiceTests PASS.

**Step 5: Commit**

```bash
git add Treemux/Services/Git/GitRepositoryService.swift Tests/GitRepositoryServiceTests.swift
git commit -m "feat: add git repository service with worktree support"
```

---

### Task 9: Ghostty Runtime and Controller

**Files:**
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyRuntime.swift`
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyController.swift`
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyControllerRegistry.swift`
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyClipboardSupport.swift`
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyInputSupport.swift`
- Create: `Treemux/Services/Terminal/Ghostty/TreemuxGhosttyShellIntegration.swift`
- Create: `Treemux/Services/Terminal/ShellSession.swift`
- Create: `Treemux/Services/Terminal/TerminalSurface.swift`

**Reference:** All corresponding files under `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/`

This is the largest task. Adapt Liney's Ghostty integration layer for Treemux naming.

**Step 1: Create TerminalSurface.swift — abstract protocol layer**

Reference: `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/TerminalSurface.swift`

Adapt the `TerminalSurfaceController` and `ManagedTerminalSessionSurfaceController` protocols, renaming `Liney` → `Treemux` throughout.

**Step 2: Create TreemuxGhosttyControllerRegistry.swift**

A registry that maps pointer addresses to controller instances, enabling Ghostty C callbacks to find their Swift controller.

**Step 3: Create TreemuxGhosttyRuntime.swift**

Reference: `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/Ghostty/LineyGhosttyRuntime.swift`

Adapt the singleton runtime, renaming all `Liney` → `Treemux`. Key structure:
- `ghostty_config_new()` → `ghostty_config_load_default_files()` → `ghostty_config_finalize()`
- `ghostty_app_new()` with runtime callbacks
- Wakeup, action, clipboard, close surface callbacks

**Step 4: Create TreemuxGhosttyController.swift**

Reference: `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/Ghostty/LineyGhosttyController.swift`

Per-pane controller managing `ghostty_surface_t`. Handles:
- `startManagedSessionIfNeeded()` / `restartManagedSession()` / `terminateManagedSession()`
- `sendText()`, `focus()`, search operations
- Ghostty action dispatch (split, navigate, resize, zoom, close)

**Step 5: Create TreemuxGhosttyClipboardSupport.swift and TreemuxGhosttyInputSupport.swift**

Reference: corresponding Liney files. Adapt naming.

**Step 6: Create TreemuxGhosttyShellIntegration.swift**

Reference: `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/Ghostty/LineyGhosttyShellIntegration.swift`

Wraps shell commands with Ghostty shell integration hooks for cwd tracking.

**Step 7: Create ShellSession.swift**

Reference: `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/ShellSession.swift`

Runtime wrapper around the Ghostty controller, publishing title, working directory, lifecycle state.

**Step 8: Build and verify Ghostty initializes without crash**

Run: `xcodebuild -project Treemux.xcodeproj -scheme Treemux -configuration Debug -destination 'platform=macOS,arch=arm64' build`

Expected: Build succeeds.

**Step 9: Commit**

```bash
git add Treemux/Services/Terminal/
git commit -m "feat: add Ghostty runtime, controller, and shell session layer"
```

---

### Task 10: WorkspaceStore — Central State Management

**Files:**
- Create: `Treemux/App/WorkspaceStore.swift`
- Create: `Treemux/App/TreemuxApp.swift`
- Create: `Treemux/App/WindowContext.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/App/WorkspaceStore.swift`

**Step 1: Create WorkspaceStore.swift**

```swift
// Treemux/App/WorkspaceStore.swift
import SwiftUI

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [WorkspaceModel] = []
    @Published var selectedWorkspaceID: UUID?

    private let settingsPersistence = AppSettingsPersistence()
    private let workspaceStatePersistence = WorkspaceStatePersistence()
    private let gitService = GitRepositoryService()

    var selectedWorkspace: WorkspaceModel? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var settings: AppSettings {
        didSet { try? settingsPersistence.save(settings) }
    }

    init() {
        self.settings = settingsPersistence.load()
        loadWorkspaceState()
    }

    func selectWorkspace(_ id: UUID) {
        selectedWorkspaceID = id
        saveWorkspaceState()
    }

    func addWorkspaceFromPath(_ path: URL) {
        let name = path.lastPathComponent
        let workspace = WorkspaceModel(
            id: UUID(),
            kind: .repository,
            name: name,
            repositoryRoot: path
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        saveWorkspaceState()

        Task { await refreshWorkspace(workspace) }
    }

    func addWorkspaceFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a project folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspaceFromPath(url)
    }

    func removeWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceID == id {
            selectedWorkspaceID = workspaces.first?.id
        }
        saveWorkspaceState()
    }

    func refreshWorkspace(_ workspace: WorkspaceModel) async {
        guard let root = workspace.repositoryRoot else { return }
        do {
            let snapshot = try await gitService.inspectRepository(at: root)
            workspace.currentBranch = snapshot.currentBranch
            workspace.worktrees = snapshot.worktrees
            workspace.repositoryStatus = snapshot.status
        } catch {
            // Not a git repo or git failed — that's OK
        }
    }

    // MARK: - Persistence

    private func loadWorkspaceState() {
        let state = workspaceStatePersistence.load()
        selectedWorkspaceID = state.selectedWorkspaceID
        workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
    }

    func saveWorkspaceState() {
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces.map { $0.toRecord() }
        )
        try? workspaceStatePersistence.save(state)
    }
}
```

Note: `WorkspaceModel` needs to be refactored from a struct to a `@MainActor ObservableObject` class for runtime state. Add `init(from: WorkspaceRecord)` and `toRecord()` methods.

**Step 2: Create TreemuxApp.swift — application orchestrator**

Reference: `/Users/yanu/Documents/code/Terminal/liney/Liney/App/LineyDesktopApplication.swift`

```swift
// Treemux/App/TreemuxApp.swift
import AppKit
import SwiftUI

@MainActor
final class TreemuxApp {
    private var windowContext: WindowContext?

    func launch() {
        let store = WorkspaceStore()
        let window = WindowContext(store: store)
        window.show()
        self.windowContext = window
    }

    func shutdown() {
        windowContext?.store.saveWorkspaceState()
    }
}
```

**Step 3: Create WindowContext.swift**

```swift
// Treemux/App/WindowContext.swift
import AppKit
import SwiftUI

@MainActor
final class WindowContext {
    let store: WorkspaceStore
    private var window: NSWindow?

    init(store: WorkspaceStore) {
        self.store = store
    }

    func show() {
        let contentView = MainWindowView()
            .environmentObject(store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Treemux"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
```

**Step 4: Update AppDelegate to use TreemuxApp**

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var treemuxApp: TreemuxApp?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TreemuxGhosttyBootstrap.initialize()
        let app = TreemuxApp()
        app.launch()
        self.treemuxApp = app
    }

    func applicationWillTerminate(_ notification: Notification) {
        treemuxApp?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

**Step 5: Build and run**

Expected: App launches with empty main window.

**Step 6: Commit**

```bash
git add Treemux/App/ Treemux/AppDelegate.swift
git commit -m "feat: add WorkspaceStore, TreemuxApp, and WindowContext"
```

---

### Task 11: UI — Main Window with NavigationSplitView

**Files:**
- Create: `Treemux/UI/MainWindowView.swift`
- Create: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`
- Create: `Treemux/UI/Workspace/WorkspaceDetailView.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/MainWindowView.swift`

**Step 1: Create MainWindowView.swift**

```swift
// Treemux/UI/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView()
        } detail: {
            if store.selectedWorkspace != nil {
                WorkspaceDetailView()
            } else {
                Text(String(localized: "Select or open a project"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

**Step 2: Create placeholder WorkspaceSidebarView.swift**

```swift
// Treemux/UI/Sidebar/WorkspaceSidebarView.swift
import SwiftUI

struct WorkspaceSidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack {
            List(selection: $store.selectedWorkspaceID) {
                Section("Local Projects") {
                    ForEach(store.workspaces) { workspace in
                        Text(workspace.name)
                            .tag(workspace.id)
                    }
                }
            }

            Button(String(localized: "Open Project...")) {
                store.addWorkspaceFromOpenPanel()
            }
            .padding()
        }
    }
}
```

**Step 3: Create placeholder WorkspaceDetailView.swift**

```swift
// Treemux/UI/Workspace/WorkspaceDetailView.swift
import SwiftUI

struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            VStack {
                Text(workspace.name)
                    .font(.title)
                Text(workspace.currentBranch ?? "No branch")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

**Step 4: Build and run**

Expected: App shows NavigationSplitView with sidebar listing workspaces and "Open Project..." button. Clicking the button opens folder picker; selecting a folder adds it to the sidebar.

**Step 5: Commit**

```bash
git add Treemux/UI/
git commit -m "feat: add main window with NavigationSplitView, sidebar, and detail view"
```

---

### Task 12: UI — Terminal Pane Embedding

**Files:**
- Create: `Treemux/UI/Components/TerminalHostView.swift`
- Create: `Treemux/UI/Workspace/TerminalPaneView.swift`
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Components/TerminalHostView.swift`

**Step 1: Create TerminalHostView.swift — NSViewRepresentable bridge to Ghostty**

```swift
// Treemux/UI/Components/TerminalHostView.swift
import SwiftUI
import GhosttyKit

struct TerminalHostView: NSViewRepresentable {
    let controller: TreemuxGhosttyController

    func makeNSView(context: Context) -> NSView {
        controller.surfaceView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Ghostty manages its own rendering
    }
}
```

**Step 2: Create TerminalPaneView.swift**

```swift
// Treemux/UI/Workspace/TerminalPaneView.swift
import SwiftUI

struct TerminalPaneView: View {
    @ObservedObject var session: ShellSession

    var body: some View {
        VStack(spacing: 0) {
            // Pane header
            HStack {
                Text(session.title ?? "Terminal")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(session.workingDirectory ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Terminal surface
            TerminalHostView(controller: session.controller)
        }
    }
}
```

**Step 3: Update WorkspaceDetailView to embed a single terminal**

For now, show a single terminal pane when a workspace is selected.

```swift
// Update WorkspaceDetailView to create and show a terminal pane
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace,
           let session = workspace.sessionController.primarySession {
            TerminalPaneView(session: session)
        } else {
            Text(String(localized: "No active session"))
                .foregroundStyle(.secondary)
        }
    }
}
```

**Step 4: Build and run**

Expected: Selecting a project shows a working terminal pane with Ghostty rendering. You can type commands.

**Step 5: Commit**

```bash
git add Treemux/UI/Components/TerminalHostView.swift Treemux/UI/Workspace/
git commit -m "feat: embed Ghostty terminal pane in workspace detail view"
```

---

### Task 13: UI — Split Node View (Recursive Pane Splitting)

**Files:**
- Create: `Treemux/UI/Workspace/SplitNodeView.swift`
- Create: `Treemux/UI/Workspace/SplitDivider.swift`
- Create: `Treemux/Services/Terminal/WorkspaceSessionController.swift`
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift`

**Reference:**
- `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Workspace/SplitNodeView.swift`
- `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Terminal/WorkspaceSessionController.swift`

**Step 1: Create WorkspaceSessionController.swift**

Manages the collection of ShellSession instances for a workspace.

```swift
// Treemux/Services/Terminal/WorkspaceSessionController.swift
import Foundation

@MainActor
final class WorkspaceSessionController: ObservableObject {
    @Published var sessions: [UUID: ShellSession] = [:]
    @Published var layout: SessionLayoutNode
    @Published var focusedPaneID: UUID?
    @Published var zoomedPaneID: UUID?

    private let workingDirectory: URL?

    init(workingDirectory: URL?) {
        self.workingDirectory = workingDirectory
        let initialPaneID = UUID()
        self.layout = .pane(PaneLeaf(paneID: initialPaneID))
        self.focusedPaneID = initialPaneID
    }

    var primarySession: ShellSession? {
        sessions.values.first
    }

    func ensureSession(for paneID: UUID) -> ShellSession {
        if let existing = sessions[paneID] { return existing }
        let session = ShellSession(id: paneID, workingDirectory: workingDirectory)
        sessions[paneID] = session
        return session
    }

    func splitPane(_ paneID: UUID, axis: SplitAxis) {
        let newPaneID = UUID()
        splitLayout(&layout, target: paneID, axis: axis, newPaneID: newPaneID)
        focusedPaneID = newPaneID
    }

    func closePane(_ paneID: UUID) {
        sessions[paneID]?.terminate()
        sessions.removeValue(forKey: paneID)
        layout.removePane(paneID)
        if focusedPaneID == paneID {
            focusedPaneID = layout.paneIDs.first
        }
    }

    func focusNext() {
        guard let current = focusedPaneID else { return }
        focusedPaneID = layout.paneID(in: .next, from: current)
    }

    func focusPrevious() {
        guard let current = focusedPaneID else { return }
        focusedPaneID = layout.paneID(in: .previous, from: current)
    }

    func toggleZoom() {
        if zoomedPaneID != nil {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = focusedPaneID
        }
    }

    private func splitLayout(_ node: inout SessionLayoutNode, target: UUID, axis: SplitAxis, newPaneID: UUID) {
        switch node {
        case .pane(let leaf) where leaf.paneID == target:
            node = .split(PaneSplitNode(
                axis: axis,
                fraction: 0.5,
                first: .pane(leaf),
                second: .pane(PaneLeaf(paneID: newPaneID))
            ))
        case .split(var splitNode):
            splitLayout(&splitNode.first, target: target, axis: axis, newPaneID: newPaneID)
            splitLayout(&splitNode.second, target: target, axis: axis, newPaneID: newPaneID)
            node = .split(splitNode)
        default:
            break
        }
    }
}
```

**Step 2: Create SplitDivider.swift**

```swift
// Treemux/UI/Workspace/SplitDivider.swift
import SwiftUI

struct SplitDivider: View {
    let axis: SplitAxis
    @Binding var fraction: Double

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(
                width: axis == .horizontal ? 2 : nil,
                height: axis == .vertical ? 2 : nil
            )
            .contentShape(Rectangle().inset(by: -3))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Fraction updated by parent based on drag delta
                    }
            )
            .cursor(axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() }
            else { NSCursor.pop() }
        }
    }
}
```

**Step 3: Create SplitNodeView.swift**

```swift
// Treemux/UI/Workspace/SplitNodeView.swift
import SwiftUI

struct SplitNodeView: View {
    @ObservedObject var sessionController: WorkspaceSessionController
    let node: SessionLayoutNode

    var body: some View {
        // If zoomed, show only the zoomed pane
        if let zoomedID = sessionController.zoomedPaneID {
            let session = sessionController.ensureSession(for: zoomedID)
            TerminalPaneView(session: session)
        } else {
            nodeView(for: node)
        }
    }

    @ViewBuilder
    private func nodeView(for node: SessionLayoutNode) -> some View {
        switch node {
        case .pane(let leaf):
            let session = sessionController.ensureSession(for: leaf.paneID)
            TerminalPaneView(session: session)

        case .split(let splitNode):
            if splitNode.axis == .horizontal {
                HSplitContent(splitNode: splitNode, sessionController: sessionController)
            } else {
                VSplitContent(splitNode: splitNode, sessionController: sessionController)
            }
        }
    }
}

private struct HSplitContent: View {
    let splitNode: PaneSplitNode
    @ObservedObject var sessionController: WorkspaceSessionController

    var body: some View {
        GeometryReader { geometry in
            let leftWidth = geometry.size.width * splitNode.clampedFraction
            HStack(spacing: 0) {
                SplitNodeView(sessionController: sessionController, node: splitNode.first)
                    .frame(width: leftWidth)
                SplitDivider(axis: .horizontal, fraction: .constant(splitNode.fraction))
                SplitNodeView(sessionController: sessionController, node: splitNode.second)
            }
        }
    }
}

private struct VSplitContent: View {
    let splitNode: PaneSplitNode
    @ObservedObject var sessionController: WorkspaceSessionController

    var body: some View {
        GeometryReader { geometry in
            let topHeight = geometry.size.height * splitNode.clampedFraction
            VStack(spacing: 0) {
                SplitNodeView(sessionController: sessionController, node: splitNode.first)
                    .frame(height: topHeight)
                SplitDivider(axis: .vertical, fraction: .constant(splitNode.fraction))
                SplitNodeView(sessionController: sessionController, node: splitNode.second)
            }
        }
    }
}
```

**Step 4: Update WorkspaceDetailView to use SplitNodeView**

```swift
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            SplitNodeView(
                sessionController: workspace.sessionController,
                node: workspace.sessionController.layout
            )
        } else {
            Text(String(localized: "No active session"))
                .foregroundStyle(.secondary)
        }
    }
}
```

**Step 5: Build and run**

Expected: App shows a single terminal pane. Ghostty keybindings or context menu can split panes.

**Step 6: Commit**

```bash
git add Treemux/UI/Workspace/ Treemux/Services/Terminal/WorkspaceSessionController.swift
git commit -m "feat: add recursive split node view with pane splitting support"
```

---

### Task 14: File System Watch Service

**Files:**
- Create: `Treemux/Services/Git/WorkspaceMetadataWatchService.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/Services/Git/WorkspaceMetadataWatchService.swift`

**Step 1: Implement WorkspaceMetadataWatchService.swift**

Use `DispatchSource.makeFileSystemObjectSource` to watch `.git` directory changes and trigger git refresh.

**Step 2: Integrate with WorkspaceStore**

When a workspace is selected, start watching its repository. On change, refresh git status.

**Step 3: Build and run**

Expected: Changing branches in a terminal updates the sidebar branch display.

**Step 4: Commit**

```bash
git add Treemux/Services/Git/WorkspaceMetadataWatchService.swift
git commit -m "feat: add file system watcher for git metadata auto-refresh"
```

---

## Phase P1: Differentiation Features

### Task 15: Theme System

**Files:**
- Create: `Treemux/Domain/ThemeDefinition.swift`
- Create: `Treemux/UI/Theme/ThemeManager.swift`
- Create: built-in theme JSON files (generated at first launch)
- Create: `Tests/ThemeTests.swift`

**Step 1: Write failing tests**

Test ThemeDefinition Codable round-trip, ThemeManager loading from directory, fallback to default theme.

**Step 2: Implement ThemeDefinition.swift**

The `ThemeDefinition` model from the design document with `TerminalColors` and `UIColors`.

**Step 3: Implement ThemeManager.swift**

`@MainActor ObservableObject` that:
- Loads active theme from settings
- Scans `~/.treemux/themes/` for available themes
- Generates built-in themes (treemux-dark.json, treemux-light.json) on first launch if missing
- Applies theme to Ghostty config and publishes UI colors

**Step 4: Integrate theme colors into UI views**

Replace hardcoded colors with `@EnvironmentObject ThemeManager` color references.

**Step 5: Run tests, build and verify**

**Step 6: Commit**

```bash
git commit -m "feat: add theme system with dark and light built-in themes"
```

---

### Task 16: Internationalization (i18n)

**Files:**
- Create: `Treemux/Localizable.xcstrings` (String Catalog)
- Create: `Treemux/Support/LanguageManager.swift`
- Modify: all UI files to use `String(localized:)`

**Step 1: Create String Catalog in Xcode**

File → New → String Catalog. Add `en` (development) and `zh-Hans` languages.

**Step 2: Implement LanguageManager.swift**

Reads `language` from settings, overrides app locale bundle.

**Step 3: Replace all hardcoded UI strings**

Go through every UI file and wrap user-visible strings with `String(localized:)`.

**Step 4: Add Chinese translations**

Fill in all `zh-Hans` entries in the String Catalog.

**Step 5: Build, switch language in settings, verify**

**Step 6: Commit**

```bash
git commit -m "feat: add i18n support with Chinese and English"
```

---

### Task 17: SSH Config Service

**Files:**
- Create: `Treemux/Services/SSH/SSHConfigService.swift`
- Create: `Treemux/Services/SSH/SSHConfigParser.swift`
- Create: `Tests/SSHConfigParserTests.swift`

**Step 1: Write failing tests for SSH config parsing**

Test parsing `~/.ssh/config` format:
```
Host server1
    HostName 192.168.1.100
    User user1
    Port 22
    IdentityFile ~/.ssh/id_rsa
```

**Step 2: Implement SSHConfigParser.swift**

Parse SSH config file into `[SSHTarget]`.

**Step 3: Implement SSHConfigService.swift**

Actor that loads SSH config, watches for changes, tests connections.

**Step 4: Run tests, verify parsing works**

**Step 5: Commit**

```bash
git commit -m "feat: add SSH config parser and service"
```

---

### Task 18: Remote Project UI

**Files:**
- Create: `Treemux/UI/Sheets/OpenProjectSheet.swift`
- Modify: `Treemux/UI/Sidebar/WorkspaceSidebarView.swift`
- Modify: `Treemux/App/WorkspaceStore.swift`

**Step 1: Create OpenProjectSheet with local/remote tabs**

Two-mode dialog: Local (folder picker) and Remote (server dropdown + path browser).

**Step 2: Update sidebar to show remote sections**

Group workspaces by type: local projects in one section, each server+user as separate sections with connection status dots.

**Step 3: Add remote workspace support to WorkspaceStore**

Handle `WorkspaceKind.remote`, launch SSH sessions for remote workspaces.

**Step 4: Build and verify end-to-end flow**

**Step 5: Commit**

```bash
git commit -m "feat: add remote project support with SSH server browsing"
```

---

## Phase P2: Deep Integration

### Task 19: Tmux Service

**Files:**
- Create: `Treemux/Services/Tmux/TmuxService.swift`
- Create: `Tests/TmuxServiceTests.swift`

**Step 1: Write failing tests**

Test parsing `tmux list-sessions` output format.

**Step 2: Implement TmuxService.swift**

Actor with `listLocalSessions()`, `listRemoteSessions()`, `isSessionAlive()`, `attachCommand()`.

**Step 3: Run tests**

**Step 4: Commit**

```bash
git commit -m "feat: add tmux service for session detection"
```

---

### Task 20: Tmux Session Restoration

**Files:**
- Modify: `Treemux/Services/Terminal/ShellSession.swift`
- Modify: `Treemux/App/WorkspaceStore.swift`
- Modify: `Treemux/UI/Workspace/TerminalPaneView.swift`

**Step 1: Add tmux detection to ShellSession**

When shell integration reports process name "tmux", parse session info and update pane backend to `tmuxAttach`.

**Step 2: Add tmux badge to TerminalPaneView header**

Show 📎 icon + session name when tmux is detected.

**Step 3: Update session restoration logic in WorkspaceStore**

On app launch, for `tmuxAttach` backends: check if session alive, auto-attach or degrade.

**Step 4: Build, test manually: open tmux in a pane, quit app, relaunch, verify auto-attach**

**Step 5: Commit**

```bash
git commit -m "feat: add tmux session detection and auto-restoration"
```

---

### Task 21: AI Tool Service

**Files:**
- Create: `Treemux/Services/AITool/AIToolService.swift`
- Create: `Treemux/Domain/AIToolModels.swift`
- Create: `Tests/AIToolServiceTests.swift`

**Step 1: Write failing tests**

Test process name matching for known AI tools.

**Step 2: Implement AIToolModels.swift**

`AIToolDetection`, `AIToolKind` as defined in design.

**Step 3: Implement AIToolService.swift**

Process name detection, preset loading from `~/.treemux/agents/`, launch config generation.

**Step 4: Run tests**

**Step 5: Commit**

```bash
git commit -m "feat: add AI tool detection service"
```

---

### Task 22: AI Tool UI Integration

**Files:**
- Modify: `Treemux/UI/Workspace/TerminalPaneView.swift`
- Modify: context menu
- Modify: `Treemux/UI/Settings/SettingsSheet.swift`

**Step 1: Add AI tool badge to pane header**

Show icon (🤖 / 🔮) when AI tool detected.

**Step 2: Add context menu items**

"New Claude Code session", "New Codex session" in pane right-click menu.

**Step 3: Add AI Tools tab to settings**

Preset management UI.

**Step 4: Build and verify**

**Step 5: Commit**

```bash
git commit -m "feat: add AI tool UI integration with badges and quick launch"
```

---

## Phase P3: Polish

### Task 23: Command Palette

**Files:**
- Create: `Treemux/UI/Components/CommandPaletteView.swift`

**Reference:** `/Users/yanu/Documents/code/Terminal/liney/Liney/UI/Components/CommandPaletteView.swift`

Fuzzy-search overlay (⌘⇧P) listing all available commands.

**Step 1: Implement CommandPaletteView with fuzzy matching**

**Step 2: Register all actions as commands**

**Step 3: Commit**

```bash
git commit -m "feat: add command palette with fuzzy search"
```

---

### Task 24: Settings Sheet

**Files:**
- Create: `Treemux/UI/Settings/SettingsSheet.swift`

**Step 1: Implement tabbed settings view**

Tabs: General, Terminal, Theme, AI Tools, SSH, Shortcuts. All settings bind to `WorkspaceStore.settings`.

**Step 2: Commit**

```bash
git commit -m "feat: add settings sheet with all configuration tabs"
```

---

### Task 25: Keyboard Shortcuts

**Files:**
- Modify: `Treemux/AppDelegate.swift` (menu bar with shortcuts)
- Modify: `Treemux/App/TreemuxApp.swift` (action dispatch)

**Step 1: Define all shortcuts in menu bar**

⌘T (new tab), ⌘W (close pane), ⌘D (split horizontal), ⌘⇧D (split vertical), etc.

**Step 2: Wire shortcuts to WorkspaceStore/SessionController actions**

**Step 3: Commit**

```bash
git commit -m "feat: add keyboard shortcuts for all major actions"
```

---

## Dependency Graph

```
Task 1 (Project setup)
  → Task 2 (GhosttyKit vendor)
    → Task 9 (Ghostty runtime/controller)
      → Task 12 (Terminal pane UI)
        → Task 13 (Split node view)

Task 3 (PaneLayout model)
  → Task 13 (Split node view)

Task 4 (Session backend models)
Task 5 (Workspace models)
  → Task 6 (Persistence)
    → Task 10 (WorkspaceStore)
      → Task 11 (Main window UI)
        → Task 12 (Terminal pane UI)

Task 7 (Shell command runner)
  → Task 8 (Git service)
    → Task 14 (File system watcher)

Task 10 (WorkspaceStore)
  → Task 15 (Theme system)
  → Task 16 (i18n)
  → Task 17 (SSH config service) → Task 18 (Remote project UI)
  → Task 19 (Tmux service) → Task 20 (Tmux restoration)
  → Task 21 (AI tool service) → Task 22 (AI tool UI)
  → Task 23 (Command palette)
  → Task 24 (Settings sheet)
  → Task 25 (Keyboard shortcuts)
```
