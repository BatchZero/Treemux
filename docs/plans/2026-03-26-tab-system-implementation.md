# Tab System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add multi-tab support to Treemux so each workspace/worktree can have multiple terminal tabs, each with its own independent split layout.

**Architecture:** Extend `WorkspaceModel` with tab state management (tabs array, activeTabID, per-tab controllers). Turn `sessionController` into a computed property returning the active tab's controller. Add tab bar UI, empty state, keyboard shortcuts, persistence, and menu integration.

**Tech Stack:** Swift, SwiftUI, macOS (AppKit interop), Codable persistence

---

### Task 1: Extend WorkspaceTabStateRecord with isManuallyNamed

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:40-47`
- Test: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write the failing test**

Add to `TreemuxTests/WorkspaceModelsTests.swift`:

```swift
func testTabStateRecordCodableRoundTrip() throws {
    let tab = WorkspaceTabStateRecord(
        id: UUID(),
        title: "My Tab",
        isManuallyNamed: true,
        layout: .pane(PaneLeaf(paneID: UUID())),
        panes: [],
        focusedPaneID: nil,
        zoomedPaneID: nil
    )
    let data = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(WorkspaceTabStateRecord.self, from: data)
    XCTAssertEqual(decoded.title, "My Tab")
    XCTAssertTrue(decoded.isManuallyNamed)
}

func testTabStateRecordDefaultIsManuallyNamed() throws {
    let tab = WorkspaceTabStateRecord(
        id: UUID(),
        title: "Tab 1",
        layout: nil,
        panes: [],
        focusedPaneID: nil,
        zoomedPaneID: nil
    )
    XCTAssertFalse(tab.isManuallyNamed)
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceModelsTests/testTabStateRecordCodableRoundTrip 2>&1 | tail -5`
Expected: FAIL — `isManuallyNamed` parameter does not exist yet.

**Step 3: Implement the change**

In `Treemux/Domain/WorkspaceModels.swift`, replace the `WorkspaceTabStateRecord` struct (lines 40-47):

```swift
/// Persisted state for a single tab inside a worktree session.
struct WorkspaceTabStateRecord: Codable, Identifiable {
    let id: UUID
    var title: String
    var isManuallyNamed: Bool
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        isManuallyNamed: Bool = false,
        layout: SessionLayoutNode? = nil,
        panes: [PaneSnapshot] = [],
        focusedPaneID: UUID? = nil,
        zoomedPaneID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.isManuallyNamed = isManuallyNamed
        self.layout = layout
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }

    /// Creates a default single-pane tab for the given working directory.
    static func makeDefault(workingDirectory: String, title: String = "Tab 1") -> WorkspaceTabStateRecord {
        let paneID = UUID()
        let pane = PaneSnapshot(
            id: paneID,
            backend: .localShell(LocalShellConfig.defaultShell()),
            workingDirectory: workingDirectory
        )
        return WorkspaceTabStateRecord(
            title: title,
            layout: .pane(PaneLeaf(paneID: paneID)),
            panes: [pane],
            focusedPaneID: paneID
        )
    }

    // Support decoding old data without isManuallyNamed field
    enum CodingKeys: String, CodingKey {
        case id, title, isManuallyNamed, layout, panes, focusedPaneID, zoomedPaneID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isManuallyNamed = try container.decodeIfPresent(Bool.self, forKey: .isManuallyNamed) ?? false
        layout = try container.decodeIfPresent(SessionLayoutNode.self, forKey: .layout)
        panes = try container.decodeIfPresent([PaneSnapshot].self, forKey: .panes) ?? []
        focusedPaneID = try container.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
        zoomedPaneID = try container.decodeIfPresent(UUID.self, forKey: .zoomedPaneID)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceModelsTests 2>&1 | tail -5`
Expected: All PASS

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat(tabs): extend WorkspaceTabStateRecord with isManuallyNamed and makeDefault"
```

---

### Task 2: Add sessionSnapshots helper to WorkspaceSessionController

**Files:**
- Modify: `Treemux/Services/Terminal/WorkspaceSessionController.swift:148-156`

**Step 1: Add the helper method**

Add before `terminateAll()` (around line 148) in `WorkspaceSessionController.swift`:

```swift
// MARK: - Snapshots

/// Returns pane snapshots for all panes in layout traversal order.
func sessionSnapshots() -> [PaneSnapshot] {
    layout.paneIDs.compactMap { paneID in
        sessions[paneID]?.snapshot()
    }
}
```

**Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Services/Terminal/WorkspaceSessionController.swift
git commit -m "feat(tabs): add sessionSnapshots() helper to WorkspaceSessionController"
```

---

### Task 3: Add tab management to WorkspaceModel

This is the core runtime change. `WorkspaceModel` gains `tabs`, `activeTabID`, tab CRUD methods, and `sessionController` becomes a computed property.

**Files:**
- Modify: `Treemux/Domain/WorkspaceModels.swift:90-185`
- Test: `TreemuxTests/WorkspaceModelsTests.swift`

**Step 1: Write the failing tests**

Add to `TreemuxTests/WorkspaceModelsTests.swift`:

```swift
@MainActor
func testWorkspaceModelInitializesWithOneDefaultTab() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    XCTAssertEqual(ws.tabs.count, 1)
    XCTAssertNotNil(ws.activeTabID)
    XCTAssertEqual(ws.tabs.first?.id, ws.activeTabID)
}

@MainActor
func testCreateTabAddsAndActivates() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    let originalTabID = ws.activeTabID
    ws.createTab()
    XCTAssertEqual(ws.tabs.count, 2)
    XCTAssertNotEqual(ws.activeTabID, originalTabID)
}

@MainActor
func testCloseTabRemovesAndSelectsAdjacent() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    ws.createTab()
    ws.createTab()
    XCTAssertEqual(ws.tabs.count, 3)

    let middleTab = ws.tabs[1]
    ws.selectTab(middleTab.id)
    ws.closeTab(middleTab.id)

    XCTAssertEqual(ws.tabs.count, 2)
    XCTAssertNotNil(ws.activeTabID)
    XCTAssertFalse(ws.tabs.contains { $0.id == middleTab.id })
}

@MainActor
func testCloseLastTabResultsInEmptyState() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    let tabID = ws.tabs[0].id
    ws.closeTab(tabID)
    XCTAssertTrue(ws.tabs.isEmpty)
    XCTAssertNil(ws.activeTabID)
}

@MainActor
func testRenameTabSetsManuallyNamed() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    let tabID = ws.tabs[0].id
    ws.renameTab(tabID, title: "My Terminal")
    XCTAssertEqual(ws.tabs[0].title, "My Terminal")
    XCTAssertTrue(ws.tabs[0].isManuallyNamed)
}

@MainActor
func testMoveTab() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    ws.createTab()
    ws.createTab()
    let firstID = ws.tabs[0].id
    let lastID = ws.tabs[2].id
    ws.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    XCTAssertEqual(ws.tabs[0].id, ws.tabs[0].id) // first shifted
    XCTAssertEqual(ws.tabs.last?.id, firstID)
}

@MainActor
func testSelectNextAndPreviousTabWraps() {
    let ws = WorkspaceModel(name: "test", kind: .localTerminal)
    ws.createTab()
    ws.createTab()
    ws.selectTab(ws.tabs[0].id)

    ws.selectPreviousTab() // wraps to last
    XCTAssertEqual(ws.activeTabID, ws.tabs[2].id)

    ws.selectNextTab() // wraps to first
    XCTAssertEqual(ws.activeTabID, ws.tabs[0].id)
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceModelsTests 2>&1 | tail -10`
Expected: FAIL — methods don't exist.

**Step 3: Implement tab management in WorkspaceModel**

Replace the `WorkspaceModel` class (lines 90-185) in `Treemux/Domain/WorkspaceModels.swift`:

```swift
// MARK: - Observable Runtime Model

/// A runtime workspace model observed by UI views via @EnvironmentObject.
/// Created from a `WorkspaceRecord` and serialized back via `toRecord()`.
@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
    let id: UUID
    let kind: WorkspaceKindRecord

    @Published var name: String
    @Published var repositoryRoot: URL?
    @Published var isPinned: Bool
    @Published var isArchived: Bool
    @Published var sshTarget: SSHTarget?
    @Published var currentBranch: String?
    @Published var worktrees: [WorktreeModel] = []
    @Published var repositoryStatus: RepositoryStatusSnapshot?
    /// Custom display order of worktrees (paths). Empty means default git order.
    @Published var worktreeOrder: [String] = []

    // MARK: - Tab State

    /// All tabs for the current worktree scope.
    @Published var tabs: [WorkspaceTabStateRecord] = []
    /// The currently active tab ID.
    @Published var activeTabID: UUID?

    /// Per-worktree, per-tab session controllers.
    /// Key: worktreePath (empty string for workspace root), Value: [tabID: controller]
    private var tabControllers: [String: [UUID: WorkspaceSessionController]] = [:]

    /// Saved tab state per worktree path (used when switching worktrees).
    private var worktreeTabStates: [String: (tabs: [WorkspaceTabStateRecord], activeTabID: UUID?)] = [:]

    // MARK: - Active Controller

    /// The session controller for the currently active tab.
    /// Returns nil when no tabs exist (empty state).
    var sessionController: WorkspaceSessionController? {
        guard let tabID = activeTabID else { return nil }
        return controller(forTabID: tabID, worktreePath: activeWorktreePath)
    }

    /// Session controller for a specific worktree path (used by WorkspaceStore).
    /// Returns the active tab's controller for that worktree.
    func sessionController(forWorktreePath path: String) -> WorkspaceSessionController? {
        // If switching worktree, load that worktree's tabs
        if path != activeWorktreePath {
            switchToWorktree(path)
        }
        return sessionController
    }

    /// The current worktree path scope. Empty string means workspace root.
    private(set) var activeWorktreePath: String = ""

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        name: String,
        kind: WorkspaceKindRecord,
        repositoryRoot: URL? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        sshTarget: SSHTarget? = nil,
        worktreeOrder: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.repositoryRoot = repositoryRoot
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sshTarget = sshTarget
        self.worktreeOrder = worktreeOrder

        let workingDirectory = repositoryRoot?.path ?? NSHomeDirectory()
        self.activeWorktreePath = workingDirectory

        // Initialize with a single default tab
        let defaultTab = WorkspaceTabStateRecord.makeDefault(
            workingDirectory: workingDirectory
        )
        self.tabs = [defaultTab]
        self.activeTabID = defaultTab.id
    }

    /// Creates a runtime model from a persisted record.
    convenience init(from record: WorkspaceRecord) {
        self.init(
            id: record.id,
            name: record.name,
            kind: record.kind,
            repositoryRoot: record.repositoryPath.map { URL(fileURLWithPath: $0) },
            isPinned: record.isPinned,
            isArchived: record.isArchived,
            sshTarget: record.sshTarget,
            worktreeOrder: record.worktreeOrder ?? []
        )

        // Restore tab state from persisted worktree states
        restoreTabState(from: record.worktreeStates)
    }

    // MARK: - Tab Operations

    /// Creates a new tab and switches to it.
    func createTab() {
        saveActiveTabState()
        let workingDirectory = activeWorktreePath
        let newIndex = tabs.count + 1
        let newTab = WorkspaceTabStateRecord.makeDefault(
            workingDirectory: workingDirectory,
            title: "Tab \(newIndex)"
        )
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    /// Switches to the specified tab.
    func selectTab(_ tabID: UUID) {
        guard tabID != activeTabID,
              tabs.contains(where: { $0.id == tabID }) else { return }
        saveActiveTabState()
        activeTabID = tabID
    }

    /// Closes the specified tab and its sessions.
    func closeTab(_ tabID: UUID) {
        saveActiveTabState()

        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // Terminate and remove controller
        let path = activeWorktreePath
        if let ctrl = tabControllers[path]?[tabID] {
            ctrl.terminateAll()
            tabControllers[path]?.removeValue(forKey: tabID)
        }

        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
        } else if activeTabID == tabID {
            // Select adjacent tab (prefer same index, fallback to last)
            let newIndex = min(index, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }
    }

    /// Renames a tab and marks it as manually named.
    func renameTab(_ tabID: UUID, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabs[index].title = trimmed
        tabs[index].isManuallyNamed = true
    }

    /// Reorders tabs via drag and drop.
    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    /// Selects the next tab, wrapping around.
    func selectNextTab() {
        guard tabs.count > 1,
              let currentID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        saveActiveTabState()
        let nextIndex = (index + 1) % tabs.count
        activeTabID = tabs[nextIndex].id
    }

    /// Selects the previous tab, wrapping around.
    func selectPreviousTab() {
        guard tabs.count > 1,
              let currentID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        saveActiveTabState()
        let prevIndex = (index - 1 + tabs.count) % tabs.count
        activeTabID = tabs[prevIndex].id
    }

    /// Selects a tab by its 1-based position (for ⌘1-⌘9 shortcuts).
    func selectTabByNumber(_ number: Int) {
        let index = number - 1
        guard index >= 0, index < tabs.count else { return }
        selectTab(tabs[index].id)
    }

    // MARK: - Title Auto-Generation

    /// Returns a suggested title for the active tab based on focused pane state.
    func suggestedTitle(for ctrl: WorkspaceSessionController, existingTab: WorkspaceTabStateRecord?) -> String {
        if existingTab?.isManuallyNamed == true {
            return existingTab?.title ?? "Tab"
        }
        if let focusedPaneID = ctrl.focusedPaneID,
           let session = ctrl.session(for: focusedPaneID) {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
            let dir = session.effectiveWorkingDirectory
            let basename = URL(fileURLWithPath: dir).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        return existingTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Tab"
    }

    // MARK: - State Save/Load

    /// Snapshots the current active tab's controller state into the tabs array.
    func saveActiveTabState() {
        guard let tabID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let ctrl = tabControllers[activeWorktreePath]?[tabID] else { return }

        let existingTab = tabs[index]
        let preferredTitle = suggestedTitle(for: ctrl, existingTab: existingTab)

        tabs[index] = WorkspaceTabStateRecord(
            id: tabID,
            title: preferredTitle,
            isManuallyNamed: existingTab.isManuallyNamed,
            layout: ctrl.layout,
            panes: ctrl.sessionSnapshots(),
            focusedPaneID: ctrl.focusedPaneID,
            zoomedPaneID: ctrl.zoomedPaneID
        )
    }

    /// Restores tab state from persisted worktree states.
    private func restoreTabState(from worktreeStates: [WorktreeSessionStateRecord]) {
        guard let state = worktreeStates.first(where: { $0.worktreePath == activeWorktreePath })
                ?? worktreeStates.first else {
            // No saved state — keep the default single tab from init
            return
        }

        if state.tabs.isEmpty {
            // Legacy data with no tabs — keep default
            return
        }

        tabs = state.tabs
        activeTabID = state.selectedTabID ?? state.tabs.first?.id
    }

    // MARK: - Worktree Switching

    /// Switches to a different worktree, saving current and restoring target tab state.
    func switchToWorktree(_ path: String) {
        guard path != activeWorktreePath else { return }

        // Save current worktree's tab state
        saveActiveTabState()
        worktreeTabStates[activeWorktreePath] = (tabs: tabs, activeTabID: activeTabID)

        activeWorktreePath = path

        // Restore target worktree's tab state
        if let saved = worktreeTabStates[path] {
            tabs = saved.tabs
            activeTabID = saved.activeTabID
        } else {
            // First time visiting this worktree — create default tab
            let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: path)
            tabs = [defaultTab]
            activeTabID = defaultTab.id
        }
    }

    // MARK: - Controller Management

    /// Gets or creates a session controller for a specific tab.
    private func controller(forTabID tabID: UUID, worktreePath: String) -> WorkspaceSessionController {
        if let existing = tabControllers[worktreePath]?[tabID] {
            return existing
        }
        let ctrl = WorkspaceSessionController(workingDirectory: worktreePath)
        if tabControllers[worktreePath] == nil {
            tabControllers[worktreePath] = [:]
        }
        tabControllers[worktreePath]?[tabID] = ctrl
        return ctrl
    }

    // MARK: - Termination

    /// Terminates all sessions managed by this workspace.
    func terminateAllSessions() {
        for (_, controllers) in tabControllers {
            for (_, ctrl) in controllers {
                ctrl.terminateAll()
            }
        }
        tabControllers.removeAll()
    }

    // MARK: - Persistence

    /// Serializes the runtime model back to a persistable record.
    func toRecord() -> WorkspaceRecord {
        saveActiveTabState()

        // Build worktree session states
        var allWorktreeStates: [WorktreeSessionStateRecord] = []

        // Current worktree
        allWorktreeStates.append(WorktreeSessionStateRecord(
            worktreePath: activeWorktreePath,
            branch: currentBranch,
            tabs: tabs,
            selectedTabID: activeTabID
        ))

        // Other worktrees with saved tab state
        for (path, state) in worktreeTabStates where path != activeWorktreePath {
            allWorktreeStates.append(WorktreeSessionStateRecord(
                worktreePath: path,
                branch: nil,
                tabs: state.tabs,
                selectedTabID: state.activeTabID
            ))
        }

        return WorkspaceRecord(
            id: id,
            kind: kind,
            name: name,
            repositoryPath: repositoryRoot?.path,
            isPinned: isPinned,
            isArchived: isArchived,
            sshTarget: sshTarget,
            worktreeStates: allWorktreeStates,
            worktreeOrder: worktreeOrder.isEmpty ? nil : worktreeOrder
        )
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/WorkspaceModelsTests 2>&1 | tail -10`
Expected: All PASS

**Step 5: Commit**

```bash
git add Treemux/Domain/WorkspaceModels.swift TreemuxTests/WorkspaceModelsTests.swift
git commit -m "feat(tabs): add tab management to WorkspaceModel"
```

---

### Task 4: Update WorkspaceStore for tab-aware controller resolution

**Files:**
- Modify: `Treemux/App/WorkspaceStore.swift:70-76`

**Step 1: Update activeSessionController**

The `activeSessionController` in `WorkspaceStore` (lines 70-76) needs to use the new `sessionController(forWorktreePath:)` which returns the active tab's controller. The current code already calls `workspace.sessionController(forWorktreePath:)` for worktrees and `workspace.sessionController` for workspace root. Since `sessionController` is now a computed property, this should just work — but verify:

```swift
/// The session controller for the currently active workspace or worktree.
/// All UI call sites (toolbar, detail view, command palette, menu bar)
/// should use this single source of truth.
var activeSessionController: WorkspaceSessionController? {
    guard let workspace = selectedWorkspace else { return nil }
    if let worktree = selectedWorktree {
        return workspace.sessionController(forWorktreePath: worktree.path.path)
    }
    return workspace.sessionController
}
```

No change needed if the types are compatible. However, `sessionController` is now `WorkspaceSessionController?` (optional), so any call site using `workspace.sessionController` non-optionally needs updating.

**Step 2: Build and fix any compilation errors**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | grep -E "error:"`

Fix all errors. The main issue will be call sites that expect `sessionController` to be non-optional. Update them to handle the optional.

**Step 3: Commit**

```bash
git add Treemux/App/WorkspaceStore.swift
git commit -m "feat(tabs): update WorkspaceStore for tab-aware controller resolution"
```

---

### Task 5: Create WorkspaceTabBarView

**Files:**
- Create: `Treemux/UI/Workspace/WorkspaceTabBarView.swift`

**Step 1: Create the tab bar view**

Create `Treemux/UI/Workspace/WorkspaceTabBarView.swift`:

```swift
//
//  WorkspaceTabBarView.swift
//  Treemux

import SwiftUI

/// Tab bar displayed above the terminal area when 2+ tabs exist.
/// Shows tab buttons with title, pane count badge, close button, and drag-to-reorder.
struct WorkspaceTabBarView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var renamingTabID: UUID?
    @State private var renameText: String = ""
    @State private var hoveredTabID: UUID?
    @State private var draggedTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.tabs) { tab in
                        if renamingTabID == tab.id {
                            TabRenameField(
                                text: $renameText,
                                onCommit: {
                                    workspace.renameTab(tab.id, title: renameText)
                                    renamingTabID = nil
                                },
                                onCancel: {
                                    renamingTabID = nil
                                }
                            )
                            .frame(width: 140)
                        } else {
                            TabButton(
                                tab: tab,
                                isSelected: tab.id == workspace.activeTabID,
                                isHovered: hoveredTabID == tab.id,
                                paneCount: paneCount(for: tab),
                                onSelect: { workspace.selectTab(tab.id) },
                                onClose: { workspace.closeTab(tab.id) },
                                onRename: {
                                    renameText = tab.title
                                    renamingTabID = tab.id
                                }
                            )
                            .onHover { isHovered in
                                hoveredTabID = isHovered ? tab.id : nil
                            }
                            .onDrag {
                                draggedTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(
                                targetTabID: tab.id,
                                workspace: workspace,
                                draggedTabID: $draggedTabID
                            ))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

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
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func paneCount(for tab: WorkspaceTabStateRecord) -> Int {
        tab.layout?.paneIDs.count ?? 1
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let tab: WorkspaceTabStateRecord
    let isSelected: Bool
    let isHovered: Bool
    let paneCount: Int
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if paneCount > 1 {
                    Text("\(paneCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }

                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(.selection.opacity(0.3))
                : isHovered ? AnyShapeStyle(.quaternary)
                : AnyShapeStyle(.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.tint)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { onRename() }
            Divider()
            Button("Close Tab") { onClose() }
        }
        .gesture(TapGesture(count: 2).onEnded { onRename() })
    }
}

// MARK: - Rename Field

private struct TabRenameField: View {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Tab name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .focused($isFocused)
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
            .onAppear { isFocused = true }
    }
}

// MARK: - Drag & Drop

private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let workspace: WorkspaceModel
    @Binding var draggedTabID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedTabID,
              dragged != targetTabID,
              let fromIndex = workspace.tabs.firstIndex(where: { $0.id == dragged }),
              let toIndex = workspace.tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            workspace.moveTab(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
```

**Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceTabBarView.swift
git commit -m "feat(tabs): create WorkspaceTabBarView with drag-and-drop reorder"
```

---

### Task 6: Create EmptyTabStateView

**Files:**
- Create: `Treemux/UI/Workspace/EmptyTabStateView.swift`

**Step 1: Create the empty state view**

Create `Treemux/UI/Workspace/EmptyTabStateView.swift`:

```swift
//
//  EmptyTabStateView.swift
//  Treemux

import SwiftUI

/// Empty state shown when all tabs have been closed.
/// Displays an icon, message, and "New Terminal" button.
struct EmptyTabStateView: View {
    let onCreateTab: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("No open terminals")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button(action: onCreateTab) {
                Label("New Terminal", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("⌘T to create a new tab")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/EmptyTabStateView.swift
git commit -m "feat(tabs): create EmptyTabStateView for zero-tab state"
```

---

### Task 7: Integrate tab bar into WorkspaceDetailView

**Files:**
- Modify: `Treemux/UI/Workspace/WorkspaceDetailView.swift`

**Step 1: Update WorkspaceDetailView to show tab bar and handle empty state**

Replace the entire file:

```swift
//
//  WorkspaceDetailView.swift
//  Treemux

import SwiftUI

/// Detail view for the selected workspace.
/// Displays the tab bar (when 2+ tabs), split pane layout, or empty state.
struct WorkspaceDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        if let workspace = store.selectedWorkspace {
            WorkspaceTabContainerView(workspace: workspace)
                .id(store.selectedWorkspaceID)
        }
    }
}

/// Container that manages tab bar visibility and routes to the active tab's content.
private struct WorkspaceTabContainerView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar: shown when 2+ tabs
            if workspace.tabs.count > 1 {
                WorkspaceTabBarView(workspace: workspace)
            }

            // Content area
            if let controller = workspace.sessionController {
                WorkspaceSessionDetailView(controller: controller)
                    .id(workspace.activeTabID)
            } else {
                EmptyTabStateView {
                    workspace.createTab()
                }
            }
        }
    }
}

/// Observes the session controller directly so that layout mutations
/// (e.g. splitPane) propagate to SplitNodeView.
private struct WorkspaceSessionDetailView: View {
    @ObservedObject var controller: WorkspaceSessionController

    var body: some View {
        SplitNodeView(sessionController: controller, node: controller.layout)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Workspace/WorkspaceDetailView.swift
git commit -m "feat(tabs): integrate tab bar and empty state into WorkspaceDetailView"
```

---

### Task 8: Update MainWindowView toolbar — "New Terminal" creates tab

**Files:**
- Modify: `Treemux/UI/MainWindowView.swift:68-76`

**Step 1: Change "New Terminal" button to create a tab**

Replace the "New Terminal" button (lines 68-76) in `MainWindowView.swift`:

```swift
Button {
    store.selectedWorkspace?.createTab()
} label: {
    Image(systemName: "plus.rectangle")
}
.help("New Terminal (⌘T)")
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/MainWindowView.swift
git commit -m "feat(tabs): toolbar New Terminal button creates tab instead of split"
```

---

### Task 9: Add tab shortcut actions

**Files:**
- Modify: `Treemux/Domain/ShortcutAction.swift`

**Step 1: Add tab actions to ShortcutAction enum**

Add a new `tabs` category and new actions. Replace the entire file:

```swift
//
//  ShortcutAction.swift
//  Treemux
//

import Foundation

// MARK: - Shortcut Category

enum ShortcutCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case tabs
    case panes
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .tabs: return String(localized: "Tabs")
        case .panes: return String(localized: "Panes")
        case .window: return String(localized: "Window")
        }
    }
}

// MARK: - Shortcut Action

enum ShortcutAction: String, CaseIterable, Hashable, Identifiable {
    case openSettings
    case commandPalette
    case toggleSidebar
    case openProject
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case splitHorizontal
    case splitVertical
    case closePane
    case focusNextPane
    case focusPreviousPane
    case zoomPane
    case newClaudeCode

    var id: String { rawValue }

    var category: ShortcutCategory {
        switch self {
        case .openSettings, .commandPalette, .toggleSidebar, .openProject:
            return .general
        case .newTab, .closeTab, .nextTab, .previousTab:
            return .tabs
        case .splitHorizontal, .splitVertical, .closePane,
             .focusNextPane, .focusPreviousPane, .zoomPane, .newClaudeCode:
            return .panes
        }
    }

    var title: String {
        switch self {
        case .openSettings: return String(localized: "Settings")
        case .commandPalette: return String(localized: "Command Palette")
        case .toggleSidebar: return String(localized: "Toggle Sidebar")
        case .openProject: return String(localized: "Open Project")
        case .newTab: return String(localized: "New Tab")
        case .closeTab: return String(localized: "Close Tab")
        case .nextTab: return String(localized: "Next Tab")
        case .previousTab: return String(localized: "Previous Tab")
        case .splitHorizontal: return String(localized: "Split Down")
        case .splitVertical: return String(localized: "Split Right")
        case .closePane: return String(localized: "Close Pane")
        case .focusNextPane: return String(localized: "Next Pane")
        case .focusPreviousPane: return String(localized: "Previous Pane")
        case .zoomPane: return String(localized: "Zoom Pane")
        case .newClaudeCode: return String(localized: "New Claude Code Session")
        }
    }

    var subtitle: String {
        switch self {
        case .openSettings: return String(localized: "Open the Treemux settings panel.")
        case .commandPalette: return String(localized: "Search and run commands.")
        case .toggleSidebar: return String(localized: "Show or hide the project sidebar.")
        case .openProject: return String(localized: "Open a directory as a project.")
        case .newTab: return String(localized: "Create a new terminal tab.")
        case .closeTab: return String(localized: "Close the current tab.")
        case .nextTab: return String(localized: "Switch to the next tab.")
        case .previousTab: return String(localized: "Switch to the previous tab.")
        case .splitHorizontal: return String(localized: "Split the focused pane downward.")
        case .splitVertical: return String(localized: "Split the focused pane to the right.")
        case .closePane: return String(localized: "Close the focused pane.")
        case .focusNextPane: return String(localized: "Move focus to the next pane.")
        case .focusPreviousPane: return String(localized: "Move focus to the previous pane.")
        case .zoomPane: return String(localized: "Zoom or unzoom the focused pane.")
        case .newClaudeCode: return String(localized: "Open a new Claude Code terminal.")
        }
    }

    var defaultShortcut: StoredShortcut? {
        switch self {
        case .openSettings:
            return StoredShortcut(key: ",", command: true, shift: false, option: false, control: false)
        case .commandPalette:
            return StoredShortcut(key: "p", command: true, shift: true, option: false, control: false)
        case .toggleSidebar:
            return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        case .openProject:
            return StoredShortcut(key: "o", command: true, shift: false, option: false, control: false)
        case .newTab:
            return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
        case .closeTab:
            return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
        case .nextTab:
            return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
        case .previousTab:
            return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
        case .splitHorizontal:
            return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
        case .splitVertical:
            return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
        case .closePane:
            return StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)
        case .focusNextPane:
            return StoredShortcut(key: "]", command: true, shift: false, option: false, control: false)
        case .focusPreviousPane:
            return StoredShortcut(key: "[", command: true, shift: false, option: false, control: false)
        case .zoomPane:
            return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
        case .newClaudeCode:
            return StoredShortcut(key: "c", command: true, shift: true, option: false, control: false)
        }
    }
}
```

Key shortcut assignments:
- `⌘T` = New Tab
- `⌘⇧W` = Close Tab (note: `⌘W` is Close Pane)
- `⌘⇧]` = Next Tab (note: `⌘]` is Next Pane)
- `⌘⇧[` = Previous Tab (note: `⌘[` is Previous Pane)

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/Domain/ShortcutAction.swift
git commit -m "feat(tabs): add tab shortcut actions (newTab, closeTab, nextTab, previousTab)"
```

---

### Task 10: Add tab menu items to AppDelegate

**Files:**
- Modify: `Treemux/AppDelegate.swift`

**Step 1: Add Tab menu and action handlers**

In `buildMainMenu()`, add a "Tab" menu after the "Pane" menu (after line 149):

```swift
// Tab menu
let tabMenu = NSMenu(title: "Tab")
let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")
newTabItem.target = self
applyShortcut(.newTab, to: newTabItem)
tabMenu.addItem(newTabItem)
let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
closeTabItem.target = self
applyShortcut(.closeTab, to: closeTabItem)
tabMenu.addItem(closeTabItem)
tabMenu.addItem(.separator())
let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab), keyEquivalent: "")
nextTabItem.target = self
applyShortcut(.nextTab, to: nextTabItem)
tabMenu.addItem(nextTabItem)
let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(previousTab), keyEquivalent: "")
prevTabItem.target = self
applyShortcut(.previousTab, to: prevTabItem)
tabMenu.addItem(prevTabItem)
let tabMenuItem = NSMenuItem()
tabMenuItem.submenu = tabMenu
mainMenu.addItem(tabMenuItem)
```

Add the action handlers after the existing `zoomPane()` method:

```swift
@objc private func newTab() {
    store?.selectedWorkspace?.createTab()
}

@objc private func closeTab() {
    guard let ws = store?.selectedWorkspace, let tabID = ws.activeTabID else { return }
    ws.closeTab(tabID)
}

@objc private func nextTab() {
    store?.selectedWorkspace?.selectNextTab()
}

@objc private func previousTab() {
    store?.selectedWorkspace?.selectPreviousTab()
}
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/AppDelegate.swift
git commit -m "feat(tabs): add Tab menu with New/Close/Next/Previous items"
```

---

### Task 11: Add tab commands to CommandPaletteView

**Files:**
- Modify: `Treemux/UI/Components/CommandPaletteView.swift`

**Step 1: Add tab commands to the allCommands list**

In `CommandPaletteView.swift`, add tab commands to the `allCommands` array (inside the computed property, around line 120-185). Insert before the existing Split Down command:

```swift
PaletteCommand(
    title: "New Tab",
    subtitle: "Create a new terminal tab",
    icon: "plus.rectangle",
    shortcut: store.settings.shortcutDisplayString(for: .newTab),
    action: { store.selectedWorkspace?.createTab() }
),
PaletteCommand(
    title: "Close Tab",
    subtitle: "Close the current tab",
    icon: "xmark.rectangle",
    shortcut: store.settings.shortcutDisplayString(for: .closeTab),
    action: {
        if let ws = store.selectedWorkspace, let tabID = ws.activeTabID {
            ws.closeTab(tabID)
        }
    }
),
PaletteCommand(
    title: "Next Tab",
    subtitle: "Switch to the next tab",
    icon: "arrow.right.square",
    shortcut: store.settings.shortcutDisplayString(for: .nextTab),
    action: { store.selectedWorkspace?.selectNextTab() }
),
PaletteCommand(
    title: "Previous Tab",
    subtitle: "Switch to the previous tab",
    icon: "arrow.left.square",
    shortcut: store.settings.shortcutDisplayString(for: .previousTab),
    action: { store.selectedWorkspace?.selectPreviousTab() }
),
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Treemux/UI/Components/CommandPaletteView.swift
git commit -m "feat(tabs): add tab commands to command palette"
```

---

### Task 12: Add persistence round-trip test

**Files:**
- Test: `TreemuxTests/PersistenceTests.swift`

**Step 1: Add test for tab state persistence**

Add to `PersistenceTests.swift`:

```swift
func testWorkspaceTabStatePersistenceRoundTrip() throws {
    let tabID = UUID()
    let paneID = UUID()
    let tab = WorkspaceTabStateRecord(
        id: tabID,
        title: "My Tab",
        isManuallyNamed: true,
        layout: .pane(PaneLeaf(paneID: paneID)),
        panes: [PaneSnapshot(
            id: paneID,
            backend: .localShell(LocalShellConfig.defaultShell()),
            workingDirectory: "/tmp"
        )],
        focusedPaneID: paneID,
        zoomedPaneID: nil
    )
    let worktreeState = WorktreeSessionStateRecord(
        worktreePath: "/tmp/project",
        branch: "main",
        tabs: [tab],
        selectedTabID: tabID
    )
    let workspace = WorkspaceRecord(
        id: UUID(),
        kind: .repository,
        name: "test",
        repositoryPath: "/tmp/project",
        isPinned: false,
        isArchived: false,
        sshTarget: nil,
        worktreeStates: [worktreeState],
        worktreeOrder: nil
    )
    let state = PersistedWorkspaceState(
        version: 1,
        selectedWorkspaceID: workspace.id,
        workspaces: [workspace]
    )

    let persistence = WorkspaceStatePersistence()
    try persistence.save(state)
    let loaded = persistence.load()

    XCTAssertEqual(loaded.workspaces.count, 1)
    let loadedWS = loaded.workspaces[0]
    XCTAssertEqual(loadedWS.worktreeStates.count, 1)
    XCTAssertEqual(loadedWS.worktreeStates[0].tabs.count, 1)
    XCTAssertEqual(loadedWS.worktreeStates[0].tabs[0].title, "My Tab")
    XCTAssertTrue(loadedWS.worktreeStates[0].tabs[0].isManuallyNamed)
    XCTAssertEqual(loadedWS.worktreeStates[0].selectedTabID, tabID)
}

func testWorkspaceTabStateMigrationFromEmptyTabs() throws {
    // Simulate old data with empty worktreeStates
    let workspace = WorkspaceRecord(
        id: UUID(),
        kind: .repository,
        name: "legacy",
        repositoryPath: "/tmp/legacy",
        isPinned: false,
        isArchived: false,
        sshTarget: nil,
        worktreeStates: [],
        worktreeOrder: nil
    )
    let data = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(WorkspaceRecord.self, from: data)
    XCTAssertTrue(decoded.worktreeStates.isEmpty)
    // WorkspaceModel.init(from:) will create a default tab when worktreeStates is empty
}
```

**Step 2: Run tests**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' -only-testing:TreemuxTests/PersistenceTests 2>&1 | tail -5`
Expected: All PASS

**Step 3: Commit**

```bash
git add TreemuxTests/PersistenceTests.swift
git commit -m "test(tabs): add persistence round-trip and migration tests"
```

---

### Task 13: Final integration — build, test, and verify

**Step 1: Run all tests**

Run: `xcodebuild test -scheme Treemux -destination 'platform=macOS' 2>&1 | tail -20`
Expected: All tests pass.

**Step 2: Build release**

Run: `xcodebuild build -scheme Treemux -destination 'platform=macOS' -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Manual verification checklist**

Launch the app and verify:
- [ ] Only 1 tab → tab bar hidden
- [ ] Click "New Terminal" in toolbar → new tab created, tab bar appears
- [ ] Tab shows title from process/directory
- [ ] Click between tabs → switches content
- [ ] Each tab has independent split layout
- [ ] Double-click tab title → inline rename
- [ ] Rename persists, auto-title stops updating
- [ ] Close tab × button works (hover to reveal)
- [ ] Close last tab → empty state page with "New Terminal" button
- [ ] Drag tabs to reorder
- [ ] Right-click tab → context menu
- [ ] ⌘T creates new tab
- [ ] ⌘⇧W closes current tab
- [ ] ⌘⇧] / ⌘⇧[ switches tabs
- [ ] Quit and relaunch → tabs restored
- [ ] Menu bar "Tab" menu works

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "feat(tabs): complete tab system integration"
```

---

## File Change Summary

| File | Action | Task |
|------|--------|------|
| `Treemux/Domain/WorkspaceModels.swift` | Modify | 1, 3 |
| `Treemux/Services/Terminal/WorkspaceSessionController.swift` | Modify | 2 |
| `Treemux/App/WorkspaceStore.swift` | Modify | 4 |
| `Treemux/UI/Workspace/WorkspaceTabBarView.swift` | Create | 5 |
| `Treemux/UI/Workspace/EmptyTabStateView.swift` | Create | 6 |
| `Treemux/UI/Workspace/WorkspaceDetailView.swift` | Modify | 7 |
| `Treemux/UI/MainWindowView.swift` | Modify | 8 |
| `Treemux/Domain/ShortcutAction.swift` | Modify | 9 |
| `Treemux/AppDelegate.swift` | Modify | 10 |
| `Treemux/UI/Components/CommandPaletteView.swift` | Modify | 11 |
| `TreemuxTests/WorkspaceModelsTests.swift` | Modify | 1, 3 |
| `TreemuxTests/PersistenceTests.swift` | Modify | 12 |
